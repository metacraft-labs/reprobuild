---
title: Choose where a project's tools come from
description: Take the tools a project uses from Nix, from your PATH, from release archives, from Scoop or from source, set the default in the project file, override it for one command or one shell, and give a tool a Nix package of your own.
kind: how-to
persona: build-maintainer
domain: build
order: 30
platforms: [linux]
verifies:
  commands: [build, exec, allow]
  tests:
    - tests/integration/t_nix_tool_resolution_is_a_provisioning_edge.nim
    - libs/repro_cli_support/tests/t_path_mode_dev_env_provides_realized_tools.nim
    - libs/repro_tool_profiles/tests/t_uses_realization_version_range.nim
    - libs/repro_tool_profiles/tests/t_bootstrap_toolchain_provisioned_in_every_mode.nim
    - libs/repro_project_dsl/tests/dsl_port/t_dsl_environment_surface_is_typed.nim
unverified:
  - claim: "The repro.nim sample compiles."
    reason: "It ran on Linux with repro 0.2.24 built from reprobuild 84b459adda; no test compiles this page's samples (the snippet test reads reference/dsl.md only)."
    owner: unassigned
  - claim: "The command line overrides REPRO_TOOL_PROVISIONING, which overrides defaultToolProvisioning."
    reason: "Read from the CLI's provisioning resolution, and the variable overriding the project default was observed on Linux with repro 0.2.24 built from reprobuild 84b459adda; no test checks the order."
    owner: unassigned
  - claim: "Under path, a Nix-only package missing from PATH is not obtained from Nix by the development environment."
    reason: "The tests cited above cover a package with an archive; a Nix-only package was not run through repro exec or the shell hook."
    owner: unassigned
  - claim: "A package with no build: block runs no action under nix."
    reason: "Observed on Linux with repro 0.2.24 built from reprobuild 84b459adda (the build resolves the tools and exits 0); no test pins the behaviour per mode."
    owner: unassigned
  - claim: "The captured output on this page."
    reason: "Run by hand on Linux with repro 0.2.24 built from reprobuild 84b459adda; no scenario re-runs it."
    owner: unassigned
  - claim: "repro shell and the shell hook use the project's default, as repro build and repro exec do."
    reason: "repro build and repro exec were run; repro shell and the hook were not, and no test is cited for them."
    owner: unassigned
  - claim: "macOS behaves as Linux for every step."
    reason: "The steps were run on Linux only."
    owner: unassigned
---

# Choose where a project's tools come from

This page shows how to decide where reprobuild obtains the tools a project
names in `uses:`. They can come from Nix, from your `PATH` or from another
source, for every build or for one command.

## Before you start

- The project has a `repro.nim` whose packages name their tools in `uses:` ([Dependencies and the store](../../concepts/dependencies-and-the-store.md)).
- For the `nix` source, Nix is installed with the `nix-command` and `flakes` features enabled.

The sources are the values of
[tool provisioning](../../reference/glossary.md#tool-provisioning):

| Value | Where each tool comes from |
|---|---|
| `nix` | The Nix package the catalog names for it, built or downloaded into the Nix store |
| `path` | Your `PATH`, as it is when you run the command |
| `tarball` | A release archive the catalog names, downloaded and checked against its hash |
| `scoop` | Scoop, on Windows |
| `from-source` | A build of the tool from its source recipe |

## Steps

### 1. Set the project's default

Add `defaultToolProvisioning` to the package in `repro.nim`, beside `uses:`:

```nim fragment
package hello:
  uses:
    "nim >=2.2 <3.0"

  defaultToolProvisioning "nix"
```

Every command that obtains the package's tools uses this source unless you
override it: `repro build`, `repro exec`, `repro shell` and the shell hook.
Without a default and without an override, `repro build` refuses a package
that names tools in `uses:`:

<!-- generated:begin capture choose-where-tools-come-from no-default -->
```text
repro build: error: typed tool provisioning is required for uses declarations; refusing implicit PATH fallback. Pass --tool-provisioning=path to use the explicit weak local profile.
```
<!-- generated:end -->

:::note
Under `nix`, `repro build` runs the actions of the package's `build:` block,
with the tools obtained from Nix. A package with no `build:` block, built by
its language's [convention](../../reference/glossary.md#convention) alone,
needs `path`: under `nix`, the build obtains its tools and runs no action.
:::

### 2. Override it for one command

Pass `--tool-provisioning` to the command:

```bash
repro build --tool-provisioning=path
```

This build takes its tools from your `PATH`, whatever the project file says.

### 3. Override it for a shell session

Set `REPRO_TOOL_PROVISIONING` in the shell:

```bash
export REPRO_TOOL_PROVISIONING=path
```

The variable applies to every command you run from that shell, including
`repro exec` and `repro shell`, which take no option. `--tool-provisioning`
on a command still takes precedence over the variable.

### 4. Give a tool a Nix package the catalog does not name

When the catalog has no Nix package for a tool, declare the package yourself
in `repro.nim`, with a `provisioning:` block that names its nixpkgs attribute
and the nixpkgs revision to take it from:

```nim title="repro.nim"
import repro_project_dsl

package cowsay:
  provisioning:
    nixPackage "nixpkgs#cowsay", executablePath = "bin/cowsay",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8"

package tools:
  uses:
    "cowsay"

  defaultToolProvisioning "nix"

  devEnv:
    discard
```

`executablePath` is the program's path inside the package's store output.
The pinned revision makes every machine obtain the same package, as a
`flake.lock` does. Any package in the project can now name `cowsay` in
`uses:`.

## Check that it worked

Allow the directory once, then ask the project's environment where a tool is:

```bash
repro allow
repro exec -- which cowsay
```

A tool from Nix is in the Nix store:

<!-- generated:begin capture choose-where-tools-come-from nix-package -->
```text
Allowed repro dev-env for: ~/tools
/nix/store/2fgj127razzmajyjyc81fcjjfpj97akk-cowsay-3.8.4/bin/cowsay
```
<!-- generated:end -->

With `REPRO_TOOL_PROVISIONING=path` set, tools come from your `PATH` and
from nowhere else. A tool your `PATH` lacks, or one whose version is outside
the range the project declares, is refused: a build fails with a message
naming the tool and the remedy (`--tool-provisioning=nix` or
`--tool-provisioning=tarball`, or a per-tool override where your workspace
declares one), and the development environment reports it as unresolved.
Path mode never quietly downloads an archive or builds from Nix in its
place.

## Related

- [Move a project from a Nix flake to reprobuild](../../tutorials/move-a-project-from-a-nix-flake.md)
- [Keep an existing Nix flake as the environment](../environments/keep-a-nix-flake-environment.md)
- [Dependencies and the store](../../concepts/dependencies-and-the-store.md)
- [Coming from Nix](../../coming-from/nix.md)
