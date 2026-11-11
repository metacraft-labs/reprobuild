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
unverified:
  - claim: "The hook looks upwards from the current directory, stopping at your home directory, for repro.nim, reprobuild.nim or .repro/dev-env.lock."
    reason: "From the shell-hook design; no test is cited yet."
    owner: unassigned
  - claim: "The hook prints a message, and does not activate, in a directory you have not allowed."
    reason: "Read from the dev-env export code path; t_dev_env_allow.nim covers allow and deny but is not cited for the message."
    owner: unassigned
  - claim: "Trust is recorded against the directory's absolute path, so later changes to the project file are activated without a new prompt."
    reason: "Read from runReproAllowCommand (a file under the configuration directory named by a hash of the path). A test that edits repro.nim after allow and asserts activation is needed."
    owner: unassigned
draft: true
---

# Activate environments when you change directory

This page shows how to make your shell switch a project's environment on when
you enter the project's directory and off when you leave, the way direnv does.

## Before you start

- [Install reprobuild](../../install.md).
- The project's `repro.nim` declares a development environment.

## Steps

1. Load the hook from your shell's start-up file, once:

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

2. Open a new shell, so the start-up file runs.

3. Enter the project's directory and allow it:

   ```bash
   cd my-project
   repro allow
   ```

   The environment switches on. From now on it switches on whenever you enter
   this directory, and off when you leave it.

:::danger
Trust follows the directory, not its contents. After `repro allow`, a change to
the project's `repro.nim`, such as one that arrives with `git pull`, takes
effect the next time you enter the directory, without asking you again. Allow
only directories whose changes you would run yourself.
:::

## Withdraw trust

In the project's directory, run:

```bash
repro deny
```

The hook no longer activates the environment there. `repro allow` and
`repro deny` also take a directory as an argument.

## Check that it worked

Enter the project directory and run a tool the project declares, such as its
compiler, with `--version`. Leave the directory and run it again: the version
changes back to your system's, or the command is not found.

## Related

- [Enter a project's environment](enter-a-project-environment.md), to use an
  environment without the hook
- [Coming from direnv, devenv and mise](../../coming-from/direnv-devenv-and-mise.md)
- [Trust](../../reference/glossary.md#trust) in the glossary
