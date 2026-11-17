---
title: Drive Home Manager from a home profile
description: Name your packages once, in a reprobuild home profile, and have Home Manager install the ones each host selects, through reprobuild's Home Manager module.
kind: how-to
persona: machine-owner
domain: machines
order: 20
platforms: [linux]
verifies:
  commands: [home export, home export --check]
  tests:
    - nix/tests/home-manager.nix
    - nix/tests/lib.nix
    - tests/e2e/gm7/t_e2e_home_apply_applies_declared_concerns.nim
    - tests/e2e/m83/t_e2e_home_export_check_detects_stale_snapshot.nim
    - tests/e2e/m83/t_e2e_home_export_matches_compiled_intent.nim
unverified:
  - claim: "The captured output on this page."
    reason: "Run by hand on Linux with repro 0.2.24 built from reprobuild 84b459adda, against reprobuild-examples nix/home-manager-profile; no scenario re-runs it."
    owner: unassigned
  - claim: "The realization-source captures."
    reason: "Evaluated on Linux with the example's reprobuild input moved to eb60557254 (the first revision with realization sources) and bat added to the profile; the published example still pins 84b459adda, and its equivalence check was not built at eb60557254."
    owner: unassigned
  - claim: "The steps work for a nix-darwin or NixOS Home Manager module as for a standalone configuration."
    reason: "Only a standalone homeManagerConfiguration was evaluated."
    owner: unassigned
  - claim: "macOS behaves as Linux for every step."
    reason: "A darwin configuration was evaluated from Linux, not built or switched on a Mac."
    owner: unassigned
---

# Drive Home Manager from a home profile

This page shows how to keep Home Manager as the tool that configures your
account while the list of packages lives in a reprobuild
[home profile](../../reference/glossary.md#home-profile). You write each
package once, and every Home Manager configuration installs the packages its
host selects.

## Before you start

- A flake with a Home Manager configuration (`homeConfigurations`, or Home Manager as a NixOS or nix-darwin module).
- `repro` on your `PATH` ([Install reprobuild](../../install.md)).
- A home profile, `home.nim`, whose `hosts:` block names the hosts your configurations are for ([Machines and profiles](../../concepts/machines-and-profiles.md)).

The steps use `reprobuild-examples/nix/home-manager-profile`, whose profile
is:

```nim title="home.nim"
import repro_profile

profile "example":
  activity default:
    jq

  activity develop:
    fd
    when linux():
      htop

  activity desktop:
    vscode

  hosts:
    "laptop": [default, develop]
    "server": [default]
    "mac": [default, desktop]
```

## Steps

### 1. Export the profile

Write what the profile selects, for every host, to a file next to it:

```bash
repro home export --profile-dir . --host laptop > home-export.json
```

Commit the file. Nix reads it without running `repro`, so every machine that
evaluates the flake sees the same packages. The file holds the whole profile,
every host's activities included, and the selection of the host you name, so
one export serves every host's configuration.
[Export a home profile for Nix](export-a-home-profile.md) covers the file and
its options.

### 2. Add the reprobuild flake

Add reprobuild as an input of your flake, pinned to a release tag or a
commit, at the release you have installed or later:

```nix
inputs.reprobuild.url = "github:metacraft-labs/reprobuild/<release-tag-or-commit>";
```

The Nix side reads the export with the library of the revision you pin, and
refuses an export whose schema that library does not read.

### 3. Import the module and name the host

In the Home Manager configuration, import `reprobuild.homeManagerModules.intent`
and turn on its `packages` category:

```nix
modules = [
  reprobuild.homeManagerModules.intent
  {
    reprobuild.intent = {
      enable = true;
      host = "laptop";
      snapshot = ./home-export.json;
      packages.enable = true;
    };
  }
];
```

The module adds to `home.packages` the packages the profile selects for
`laptop`, and turns each canonical name into a nixpkgs attribute through
reprobuild's Nix catalog. Delete the same packages from your own
`home.packages` lists.

:::note
`packages.enable = true` is needed while the host's entry in `hosts:` has no
`applies:`: every category is off by default then. Once the entry declares
`applies:`, each category defaults to on unless reprobuild applies its concern
there, so remove the explicit setting at that point and let the declaration
decide.
:::

### 4. Change a package in the profile, not in Nix

To add a tool to every host that runs `develop`, add it to that activity in
`home.nim`, then export again:

```bash
repro home export --profile-dir . --host laptop > home-export.json
```

Nothing on the Nix side changes. With `just` added to `develop` in the
example, the `laptop` configuration's packages (listed as in
[Check that it worked](#check-that-it-worked)) gain `just`:

<!-- generated:begin capture drive-home-manager-from-a-profile add-a-package -->
```text
["fd-10.3.0","htop-3.4.1","jq-1.8.1","just-1.43.1","man-db-2.13.1","shared-mime-info-2.4","dummy-xdg-mime-dirs1","dummy-xdg-mime-dirs2","home-configuration-reference-manpage","hm-session-vars.sh"]
```
<!-- generated:end -->

A host that does not run `develop`, such as `server`, does not get it.

:::important
Every package the module installs needs a Nix package in reprobuild's
catalog. One without fails the evaluation and names the package, instead of
installing less than the profile declares. With `bat` added to `develop`:

<!-- generated:begin capture drive-home-manager-from-a-profile unmapped-package from="error:" -->
```text
error:
Failed assertions:
- reprobuild.intent: 1 intent entries of enabled categories could not be mapped onto Home Manager for host laptop on x86_64-linux:
  packages: package:bat: no Nix realization of `bat` in reprobuild-nix-packages, reprobuild-brew-packages
```
<!-- generated:end -->
:::

### 5. Move your own lists one activity at a time

Move each activity's packages from your Nix configuration into the profile's
activity of the same name, export, and delete them from Nix. After each one,
run [Compare a Home Manager configuration with a profile](compare-with-home-manager.md),
which fails on any package the move lost or added.

A complete set of dotfiles moved this way is not linked from this page yet.

## Take a package from another package set

A package the catalog has no Nix package for, or one you take from
nixpkgs-unstable or another flake, gets a realization source: where its Nix
package comes from, by canonical name. It never decides whether a host gets
the package; the profile does.

```nix
reprobuild.intent.realizationSources = {
  bat = { nixpkgs = pkgs; attribute = "bat"; };       # a nixpkgs-like set
  some-tool = { packages = some-flake.packages.${pkgs.stdenv.hostPlatform.system}; };
  other-tool = { derivation = other-flake.packages.${pkgs.stdenv.hostPlatform.system}.default; };
};
```

`some-flake` and `other-flake` are flake inputs you pass to the configuration,
for example through Home Manager's `extraSpecialArgs`.

The catalog has no Nix package for `bat`, so without the mapping the
evaluation refuses it. With `bat` added to `develop` and mapped as above,
`laptop` gets it:

<!-- generated:begin capture drive-home-manager-from-a-profile realization-source -->
```text
["bat-0.26.1","fd-10.3.0","htop-3.4.1","jq-1.8.1","man-db-2.13.1","shared-mime-info-2.4","dummy-xdg-mime-dirs1","dummy-xdg-mime-dirs2","home-configuration-reference-manpage","hm-session-vars.sh"]
```
<!-- generated:end -->

A mapping for a package the profile selects on no host is refused, so stale
mappings do not pile up:

<!-- generated:begin capture drive-home-manager-from-a-profile stale-mapping from="error:" -->
```text
error: reprobuild.intent.realizationSources: 1 refused mapping(s):
  realization source for `gh`: the profile selects `gh` on no host, so the mapping is stale; remove it
```
<!-- generated:end -->

[Nix library and Home Manager module](../../reference/nix-library.md#realization-sources)
lists the three kinds of source.

## Read the profile in your own Nix code

The module is built on `reprobuild.lib.readIntent`, which you can call
yourself, for example to give a NixOS module the activities of a host:

```bash
nix eval --json --impure --expr '(builtins.getFlake (toString ./.)).inputs.reprobuild.lib.readIntent { snapshot = ./home-export.json; host = "server"; system = "x86_64-linux"; }' --apply 'r: r.evaluation.packages'
```

<!-- generated:begin capture drive-home-manager-from-a-profile read-intent -->
```text
[{"activity":"default","binaries":[],"name":"jq","version":""}]
```
<!-- generated:end -->

[Nix library and Home Manager module](../../reference/nix-library.md) lists
its arguments and the other functions.

## Check that it worked

List the packages Home Manager installs for the host:

```bash
nix eval --json .#homeConfigurations.laptop.config.home.packages --apply 'map (p: p.name)'
```

<!-- generated:begin capture drive-home-manager-from-a-profile packages -->
```text
["fd-10.3.0","htop-3.4.1","jq-1.8.1","man-db-2.13.1","shared-mime-info-2.4","dummy-xdg-mime-dirs1","dummy-xdg-mime-dirs2","home-configuration-reference-manpage","hm-session-vars.sh"]
```
<!-- generated:end -->

The profile's packages are there; the rest are Home Manager's own.

## Related

- [Coming from Home Manager and NixOS](../../coming-from/home-manager-and-nixos.md): the steps after this one
- [Export a home profile for Nix](export-a-home-profile.md)
- [Compare a Home Manager configuration with a profile](compare-with-home-manager.md)
- [Install a profile's applications with Homebrew](install-applications-with-homebrew.md)
- [Nix library and Home Manager module](../../reference/nix-library.md): every function and option
