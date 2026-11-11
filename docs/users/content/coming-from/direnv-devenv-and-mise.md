---
title: Coming from direnv, devenv and mise
description: How per-directory environments, tool versions, tasks and processes from direnv, devenv and mise map onto reprobuild, and when those tools are the better choice.
kind: explanation
persona: developer
order: 30
verifies:
  commands: [shell hook, allow, deny, exec, shell, tasks, run, up, down]
  tests:
    - tests/integration/t_dev_env_allow.nim
unverified:
  - claim: "repro hooks ensure --shell-direnv writes an .envrc that hands activation to reprobuild."
    reason: "The flag is in the hooks usage text; no test is cited for the written .envrc."
    owner: unassigned
  - claim: "Trust is recorded against the directory, so a later change to repro.nim is activated without asking again."
    reason: "Read from the allow implementation; a test that edits repro.nim after repro allow is needed."
    owner: unassigned
---

# Coming from direnv, devenv and mise

This page maps what you know from direnv, devenv and mise onto reprobuild,
explains where they differ, and says when those tools remain the better choice.

## What carries over

- The environment follows the directory. Entering a project switches its environment on; leaving switches it off.
- A directory has to be allowed first. `direnv allow` and `repro allow` both stop a newly cloned repository from changing your shell before you have looked at it.
- Tool versions belong to the project. A `.mise.toml` or a `devenv.nix` names the tools a project needs; so do the `uses:` lines of a `repro.nim`.
- Tasks and processes belong to the project too, as mise tasks and devenv scripts and processes do.

## Concept map

| direnv, devenv or mise | reprobuild |
|---|---|
| `.envrc`, `devenv.nix`, `.mise.toml` | the `devEnv:` block of the [project file](../reference/glossary.md#project-file) |
| `eval "$(direnv hook bash)"` | `eval "$(repro shell hook bash)"` |
| `direnv allow`, `direnv deny` | `repro allow`, `repro deny` |
| `direnv exec DIR COMMAND` | `repro exec -- COMMAND` |
| `use flake` | `useFlakeDevShell()` |
| tool versions in `.mise.toml` | `uses:` version ranges, resolved into [`repro.lock`](../reference/glossary.md#lock-file) |
| mise tasks, devenv scripts | [tasks](../reference/glossary.md#task): `repro tasks`, `repro run` |
| devenv processes and services | [services](../reference/glossary.md#service): `repro up`, `repro down` |

## Before and after

An `.envrc` that loads a flake's dev shell:

```bash
use flake
```

becomes a `repro.nim` that does the same, with no direnv involved:

```nim
import repro_project_dsl
import repro_dsl_stdlib/foreign_env

package projectEnvironment:
  devEnv:
    useFlakeDevShell()
```

While teammates move over, `repro hooks ensure --shell-direnv` writes an
`.envrc` that hands activation to reprobuild, so people who still use direnv get
the same environment from the same `repro.nim`.

## What works differently

The environment is declared, not scripted. An `.envrc` is a shell script and
can run anything. A `devEnv:` block declares tools, variables, tasks and
services, and the compiler checks it. Where you need logic, you write it as typed
Nim in the project file.

The build uses the same environment. The tools your shell gets are the tools
the build resolves, from the same project file and the same lock file. There is
no second description of the toolchain to keep in step.

Trust follows the directory, not its contents. `repro allow` records trust
against the directory's path. After that, a change to `repro.nim`, such as one
that arrives with `git pull`, is activated the next time you enter the directory
without asking again. Allow only directories whose changes you would run
yourself.

## What reprobuild does not do

- It does not run arbitrary shell code when it activates an environment.
- It does not ask for trust again when a project file changes.
- It does not switch tool versions for directories that have no project file.

## When the other tool remains the better choice

- direnv, when you want per-directory variables with shell logic, in repositories that reprobuild does not build.
- mise or asdf, when you only switch tool versions across many unrelated repositories and have no use for a build tool.
- devenv, when your team has standardised on Nix modules for services and wants those modules, not reprobuild's services.

## Next steps

- [Activate environments when you change directory](../guides/environments/activate-on-directory-change.md)
- [Keep an existing Nix flake as the environment](../guides/environments/keep-a-nix-flake-environment.md)
- [Command equivalents](../reference/command-equivalents.md#direnv)
