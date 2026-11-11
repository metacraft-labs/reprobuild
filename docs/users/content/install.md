---
title: Install reprobuild
description: Install repro on Linux, macOS or Windows through your package manager, Nix, Scoop or a release archive, and check that it runs.
kind: how-to
persona: developer
order: 5
platforms: [linux, macos, windows]
verifies:
  commands: [version]
  tests:
    - tests/integration/t_repro_version_verb.nim
unverified:
  - claim: "Every installer option and environment variable shown on this page."
    reason: "The options block is meant to be generated from `scripts/install/repro-install.sh --help` and `repro-install.ps1 -?`; no generator exists yet, so the region is empty."
    owner: unassigned
  - claim: "Each installation path on this page installs a working repro."
    reason: "No install scenario runs these commands in clean containers yet (the OpenTofu-style install test proposed for this page)."
    owner: unassigned
  - claim: "Release archives from v0.1.4 onward carry SHA256SUMS; no release-signing key is published yet."
    reason: "Taken from the README; a check against the releases API is needed so the statement moves with the releases."
    owner: unassigned
  - claim: "On macOS and on Linux without apt or dnf, the piped installer stops because its release verifier is not bundled."
    reason: "Read from the installer's detect_method and locate_verifier; no test runs the piped installer on those platforms."
    owner: unassigned
  - claim: "The version number shown in the archive commands."
    reason: "Written as {{ repro.version }}; isonim-docs has no version interpolation yet."
    owner: unassigned
---

# Install reprobuild

This page shows each way to install `repro` and how to check that the result
runs. Pick the row for your system, follow its section, then go to
[Check that it worked](#check-that-it-worked).

| Your system | Install with | Updates come from |
|---|---|---|
| Debian, Ubuntu | [The installer](#debian-ubuntu-fedora-and-rhel-the-installer) (registers the apt repository) | `apt upgrade` |
| Fedora, RHEL, CentOS | [The installer](#debian-ubuntu-fedora-and-rhel-the-installer) (registers the dnf repository) | `dnf upgrade` |
| NixOS | [Nix and NixOS](#nix-and-nixos) (a configuration change) | your system configuration |
| Any system with Nix, including macOS | [Nix and NixOS](#nix-and-nixos) (`--method nix`) | your Nix profile |
| Windows | [The Windows installer](#windows-the-installer) (registers the Scoop bucket) | `scoop update reprobuild` |
| Anything else | [A release archive](#a-release-archive) | a new archive |

## Debian, Ubuntu, Fedora and RHEL: the installer

The installer detects your package manager, registers the Metacraft Labs
package repository and its signing key, and lets the package manager install
`reprobuild`. It needs root for the registration step.

### 1. Read the script

Read the script before you run it:

```bash
curl -fsSL https://get.reprobuild.com/sh | less
```

### 2. Run it

```bash
curl -fsSL https://get.reprobuild.com/sh | sh
```

To see the commands it would run without changing anything, add `--dry-run`:

```bash
curl -fsSL https://get.reprobuild.com/sh | sh -s -- --dry-run
```

:::note
The installer checks the downloaded keyring against a SHA-256 digest written
into the script, and the package manager checks every package against that key
from then on. The script itself arrives over HTTPS, so its own integrity rests
on the host that serves it.
:::

:::important
On macOS, and on a Linux distribution without apt or dnf, the installer falls
back to its tarball method. That method refuses to run without its release
verifier, which a piped installer does not have. Use
[Nix](#nix-and-nixos) or [a release archive](#a-release-archive) there.
:::

The installer's options:

<!-- generated:begin installer-help sh -->
<!-- generated:end -->

## Windows: the installer

The Windows installer registers the Metacraft Labs Scoop bucket and lets Scoop
install `reprobuild`. Scoop checks each download against the hash in the
bucket's manifest, on install and on every update.

### 1. Install Scoop

Install [Scoop](https://scoop.sh) if you do not have it.

### 2. Run the installer

In PowerShell, read the script, then run it:

```powershell
irm https://get.reprobuild.com/pwsh
irm https://get.reprobuild.com/pwsh | iex
```

The installer's options:

<!-- generated:begin installer-help pwsh -->
<!-- generated:end -->

## Nix and NixOS

reprobuild is packaged in the Metacraft Labs fork of nixpkgs.

### NixOS

Run the installer. On NixOS it installs nothing and prints the change to make
to your system configuration:

```bash
curl -fsSL https://get.reprobuild.com/sh | sh
```

### Nix on any other system, including macOS

Install into your Nix profile:

```bash
curl -fsSL https://get.reprobuild.com/sh | sh -s -- --method nix
```

## A release archive

Each [release](https://github.com/metacraft-labs/reprobuild/releases) carries an
archive per platform and a `SHA256SUMS` file.

### 1. Download the archive and the checksum file

Set the version and your platform, then download both files:

```bash
VERSION={{ repro.version }}
PLATFORM=linux-x86_64
BASE=https://github.com/metacraft-labs/reprobuild/releases/download/v${VERSION}
curl -fsSLO "${BASE}/reprobuild-${VERSION}-${PLATFORM}.tar.gz"
curl -fsSLO "${BASE}/SHA256SUMS"
```

:::tabs
@tab Linux
Use `PLATFORM=linux-x86_64`.

@tab macOS
Use `PLATFORM=darwin-aarch64`.

@tab Windows
Download `reprobuild-<version>-windows-x86_64.zip` from the release page.
:::

### 2. Check the archive against the checksum file

:::tabs
@tab Linux
```bash
sha256sum --ignore-missing -c SHA256SUMS
```

@tab macOS
```bash
shasum -a 256 --ignore-missing -c SHA256SUMS
```

@tab Windows
```powershell
Get-FileHash .\reprobuild-<version>-windows-x86_64.zip -Algorithm SHA256
```

Compare the printed hash with the archive's line in `SHA256SUMS`.
:::

### 3. Unpack it and put its bin directory on your PATH

```bash
tar -xzf "reprobuild-${VERSION}-${PLATFORM}.tar.gz"
export PATH="${PWD}/reprobuild-${VERSION}-${PLATFORM}/bin:${PATH}"
```

:::important
Keep `bin/` and `lib/` together. `repro` loads its libraries from a path
relative to its own location, so a `repro` copied out of the unpacked directory
on its own does not start.
:::

:::danger
A checksum detects a corrupted download. It does not prove who built the
archive: the checksum file comes from the same place as the archive, and no
release-signing key is published yet.
:::

## Check that it worked

Run:

```bash
repro version
```

It prints the version of the `repro` on your `PATH`. `repro version --json`
prints the same information as JSON, with the protocol versions this binary
speaks. Neither needs a project or a running daemon.

<!-- generated:begin capture install version -->
<!-- generated:end -->

## Uninstall

- Installer: run it with `--uninstall`, shown below. It removes the package, the repository registration and the signing key, then checks that they are gone.
- Windows: `scoop uninstall reprobuild`.
- Nix: remove `reprobuild` from your profile or your system configuration.
- Release archive: delete the unpacked directory and remove it from `PATH`.

To uninstall with the installer:

```bash
curl -fsSL https://get.reprobuild.com/sh | sh -s -- --uninstall
```

## Related

- [Build your first project](tutorials/first-build.md)
- [Diagnose your setup with `repro health`](guides/troubleshooting/diagnose-with-repro-health.md)
