---
title: Compare a Home Manager configuration with a profile
description: Check that a Home Manager configuration gives a host the same packages, files, environment and services as its reprobuild home profile, excuse the differences you accept with a reason, and run the comparison as a flake check.
kind: how-to
persona: machine-owner
domain: machines
order: 40
platforms: [linux]
verifies:
  commands: [home facts, home compare]
  tests:
    - nix/tests/home-equivalence.nix
    - nix/tests/host-facts.nix
    - tests/e2e/m83/t_e2e_home_facts_from_isolated_plan.nim
    - tests/e2e/m83/t_e2e_compare_reports_each_category.nim
    - tests/e2e/m83/t_e2e_compare_allowlist_requires_reasons.nim
    - tests/e2e/m83/t_e2e_compare_unmapped_is_not_different.nim
unverified:
  - claim: "The captured output on this page."
    reason: "Run by hand on Linux with repro 0.2.24 built from reprobuild 84b459adda, against reprobuild-examples nix/home-manager-profile; no scenario re-runs it."
    owner: unassigned
  - claim: "The darwin side compares launchd agents and Homebrew tokens as the Linux side compares systemd units and packages."
    reason: "Only a Linux configuration was compared."
    owner: unassigned
---

# Compare a Home Manager configuration with a profile

This page shows how to check that a Home Manager configuration and a
reprobuild [home profile](../../reference/glossary.md#home-profile) give a
host the same thing, so you know before you hand a part of the host from one
to the other.

## Before you start

- A flake with a Home Manager configuration for the host, and the reprobuild flake as an input ([Drive Home Manager from a home profile](drive-home-manager-from-a-profile.md)).
- A home profile whose `hosts:` block declares the host.

The comparison covers four categories:

| Category | Home Manager side | Profile side |
|---|---|---|
| packages | `home.packages`, by canonical package name | the packages the host's activities select |
| files | `home.file` and `xdg.configFile` | the files the profile places |
| environment | `home.sessionVariables`, `home.sessionPath` | the profile's variables and `PATH` entries |
| services | `systemd.user` units, `launchd.agents` | the profile's user services |

It compares which packages a host gets. It does not compare their versions or
how they are built. [Host facts](../../reference/files/host-facts.md) lists
every field of the documents it compares.

## Steps

### 1. Add the check to the flake

```nix
checks.x86_64-linux.home-equivalence-laptop = reprobuild.lib.homeEquivalenceCheck {
  configuration = self.homeConfigurations.laptop;
  host = "laptop";
  profileDir = ./.;
  allowlist = ./home-equivalence-allow.toml;
};
```

`profileDir` is the directory that holds `home.nim`. The check runs
`repro home facts` on the profile inside the Nix build. It collects the same
facts from the configuration with `reprobuild.lib.homeManagerFacts`, and
compares the two with `repro home compare`.

### 2. Build it

```bash
nix build .#checks.x86_64-linux.home-equivalence-laptop
```

The first run of a real configuration usually lists differences that Home
Manager adds by itself. For the example, with the `allowlist` argument left
out, the report after its first line, which names the two facts files, is:

<!-- generated:begin capture compare-with-home-manager no-allowlist from-line=2 -->
```text
[packages] 3 same, 2 only in Nix, 0 only in Reprobuild, 0 different, 4 unmapped
  only-in-nix         man-db  [NOT ALLOWED]
  only-in-nix         shared-mime-info  [NOT ALLOWED]
  unmapped (nix) dummy-xdg-mime-dirs1: no Nix contribution in reprobuild-nix-packages, reprobuild-brew-packages names an attribute whose package is `dummy-xdg-mime-dirs1`
  unmapped (nix) dummy-xdg-mime-dirs2: no Nix contribution in reprobuild-nix-packages, reprobuild-brew-packages names an attribute whose package is `dummy-xdg-mime-dirs2`
  unmapped (nix) hm-session-vars.sh: no Nix contribution in reprobuild-nix-packages, reprobuild-brew-packages names an attribute whose package is `hm-session-vars.sh`
  unmapped (nix) home-configuration-reference-manpage: no Nix contribution in reprobuild-nix-packages, reprobuild-brew-packages names an attribute whose package is `home-configuration-reference-manpage`
[files] 0 same, 3 only in Nix, 0 only in Reprobuild, 0 different, 0 unmapped
  only-in-nix         ~/.cache/.keep  [NOT ALLOWED]
  only-in-nix         ~/.config/environment.d/10-home-manager.conf  [NOT ALLOWED]
  only-in-nix         ~/.local/state/.keep  [NOT ALLOWED]
[environment] 0 same, 1 only in Nix, 0 only in Reprobuild, 0 different, 0 unmapped
  only-in-nix         var:LOCALE_ARCHIVE_2_27  [NOT ALLOWED]
[services] 0 same, 1 only in Nix, 0 only in Reprobuild, 0 different, 0 unmapped
  only-in-nix         systemd:tray.target  [NOT ALLOWED]
result: 7 difference(s) not allowlisted, 0 stale allowlist row(s); exit 1
```
<!-- generated:end -->

Each entry is `same`, only in one side, or `different`, in which case the
report names each differing field with both values.

:::note
An `unmapped` entry is one the comparison cannot name: a package with no
canonical name in reprobuild's catalog. It never fails the comparison, so read
the unmapped list. A package you installed through Nix only, which the
catalog cannot name, shows up there and nowhere else.
:::

### 3. Excuse the differences you accept

Write each accepted difference as a row of `home-equivalence-allow.toml`, with
the reason:

```toml
[[allow]]
category = "packages"
status = "only-in-nix"
id = "man-db"
reason = "Home Manager's programs.man module, enabled by default, installs it"
```

`category` and `reason` are required; `status`, `id` (one id, or a prefix
ending in `*`) and `hosts` narrow the row. A row without a reason is refused.
A row that matches no difference fails the comparison as stale, so a row
cannot outlive the difference it excused.

### 4. Build it again

```bash
nix build .#checks.x86_64-linux.home-equivalence-laptop
```

It succeeds when every difference is excused, and writes the report to
`result/report.txt`.

## Compare outside Nix

The two halves also run on their own. `repro home facts` writes the profile's
facts for a host:

```bash
repro home facts --profile-dir . --host laptop > reprobuild.json
```

Run it as the user whose home it describes, or say where that home is. A
`PATH` entry that spells the home by its absolute path, such as
`/home/alice/.local/bin`, is named `~/.local/bin` on both sides only when
both know the same home directory. Home Manager knows it as
`home.homeDirectory`; `repro home facts` takes it from `--home-dir`, or from
`$HOME` when the flag is absent:

```bash
repro home facts --profile-dir . --host laptop --home-dir /home/alice > reprobuild.json
```

The check's output directory holds the Home Manager side as `nix.json`.
`repro home compare` takes one document of each side, in either order:

```bash
repro home compare --facts nix.json --facts reprobuild.json --allow home-equivalence-allow.toml
```

It exits 0 when nothing differs outside the allowlist, 1 when something does
or a row is stale, and 2 when the documents cannot be compared.

## Check that it worked

Add a package to the configuration on the Nix side only, for example
`home.packages = [ pkgs.gh ];`, and build the check. It fails and names the
package. The lines of the report that change are:

<!-- generated:begin capture compare-with-home-manager nix-only-package lines="^\[packages\]|  gh |^result:" -->
```text
[packages] 3 same, 3 only in Nix, 0 only in Reprobuild, 0 different, 4 unmapped
  only-in-nix         gh  [NOT ALLOWED]
result: 1 difference(s) not allowlisted, 0 stale allowlist row(s); exit 1
```
<!-- generated:end -->

Remove it again, and the check passes.

## Related

- [Drive Home Manager from a home profile](drive-home-manager-from-a-profile.md)
- [Export a home profile for Nix](export-a-home-profile.md)
- [Host facts](../../reference/files/host-facts.md)
- [Coming from Home Manager and NixOS](../../coming-from/home-manager-and-nixos.md)
