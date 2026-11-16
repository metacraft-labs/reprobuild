---
title: Activate environments when you change directory
description: Install reprobuild's shell hook so a project's environment switches on when you enter its directory and off when you leave, and grant or withdraw trust per directory.
kind: how-to
persona: developer
domain: environments
order: 20
platforms: [linux, macos, windows]
verifies:
  commands: [shell hook, allow, deny, dev-env export, dev-env deactivate]
  tests:
    - tests/integration/t_dev_env_allow.nim
    - tests/unit/t_dev_env_directory_trust_binds_recipe.nim
    - tests/e2e/dev-env/t_e2e_shell_hook_noop_latency.nim
unverified:
  - claim: "The hook looks upwards from the current directory, stopping at your home directory, for repro.nim, reprobuild.nim or .repro/dev-env.lock."
    reason: "From the shell-hook design; no test is cited yet."
    owner: unassigned
  - claim: "The hook prints a message, and does not activate, in a directory you have not allowed."
    reason: "Read from the dev-env export code path; t_dev_env_allow.nim covers allow and deny but is not cited for the message."
    owner: unassigned
---

# Activate environments when you change directory

This page shows how to make your shell switch a project's environment on when
you enter the project's directory and off when you leave, the way direnv does.

## Before you start

- [Install reprobuild](../../install.md).
- The project's `repro.nim` declares a development environment.

## Steps

### 1. Load the hook

Load the hook from your shell's start-up file, once:

:::tabs
@tab bash
Add to `~/.bashrc`:

```bash
eval "$(repro shell hook bash)"
```

@tab zsh
Add to `~/.zshrc`:

```bash
eval "$(repro shell hook zsh)"
```

@tab fish
Add to `~/.config/fish/config.fish`:

```bash
repro shell hook fish | source
```

@tab PowerShell
Add to your `$PROFILE`:

```powershell
repro shell hook pwsh | Out-String | Invoke-Expression
```

@tab Nushell
Save the output of `repro shell hook nushell` to a file and source it from
your Nushell environment configuration.
:::

### 2. Open a new shell

Open a new shell, so the start-up file runs.

### 3. Allow the project directory

Enter the project's directory and allow it:

```bash
cd my-project
repro allow
```

The environment switches on. From now on it switches on whenever you enter
this directory, and off when you leave it.

:::danger
`repro allow` trusts the project file as it is now: `repro.nim`, the local
Nim modules it imports, `config.nims` and `nim.cfg`, and the dev-env lock. If
any of them changes, for example through `git pull`, the directory stops being
trusted and the hook prints the "not allowed/trusted" message until you run
`repro allow` again. Read the change before you re-allow. Files that the
project file loads by some other route are not covered, so allow only directories
whose contents you would run yourself.
:::

## Withdraw trust

In the project's directory, run:

```bash
repro deny
```

The hook no longer activates the environment there. `repro allow` and
`repro deny` also take a directory as an argument.

## Skip the trust check where no one can answer it

In CI and other non-interactive shells, set `REPRO_DEV_ENV_AUTO_ALLOW=1` to
activate environments without `repro allow`.

:::danger
With `REPRO_DEV_ENV_AUTO_ALLOW=1`, every directory with a project file is
activated, including one you have never inspected. Set it only in a disposable
environment that runs code you already trust.
:::

## Check that it worked

Enter the project directory and run a tool the project declares, such as its
compiler, with `--version`. Leave the directory and run it again: the version
changes back to your system's, or the command is not found.

## Related

- [Enter a project's environment](enter-a-project-environment.md), to use an environment without the hook
- [Coming from direnv, devenv and mise](../../coming-from/direnv-devenv-and-mise.md)
- [Trust](../../reference/glossary.md#trust) in the glossary
