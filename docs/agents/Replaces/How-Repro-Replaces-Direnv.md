# How Reprobuild Replaces direnv

> **Status:** Skill-style comparison doc. Read on demand when you are working in
> a project that historically used direnv, or when you need to map direnv's
> activation and trust model onto Reprobuild's. For user-facing guides, see
> [Coming from direnv, devenv and mise](../../users/content/coming-from/direnv-devenv-and-mise.md),
> [Activate environments when you change directory](../../users/content/guides/environments/activate-on-directory-change.md),
> and [Enter a project's environment](../../users/content/guides/environments/enter-a-project-environment.md).

## What direnv does

[direnv](https://direnv.net/) is a shell extension that loads and unloads
environment variables based on the current directory:

- When the shell `cd`s into a directory that contains an `.envrc` (and that
  file's content is trusted for the user), direnv evaluates it in a sub-shell
  and exports the resulting environment delta into the user's shell.
- When the shell leaves that directory tree, direnv restores the previous
  environment.
- The `.envrc` is a bash script with helper functions (`PATH_add`, `use flake`,
  `source_env`, `dotenv`) that turn common patterns into one-liners.

## Reprobuild's equivalent

Reprobuild's development-environment model covers direnv's per-directory
overlay and connects it directly to the build graph:

| direnv concept | Reprobuild surface |
|---|---|
| `.envrc` | Project file (`repro.nim`) — declares `uses:` tool ranges, `devEnv:` variables, tasks, and services |
| `direnv allow` / `direnv deny` | `repro allow` / `repro deny` — binds trust to the directory's project-file closure (`repro.nim`, imported local Nim modules, `config.nims`, `nim.cfg`, and dev-env lock); revokes trust when any of those files changes |
| `use flake` / `use nix` | `useFlakeDevShell()` in `devEnv:` (via `repro_dsl_stdlib/foreign_env`), or `--tool-provisioning=nix` |
| `PATH_add` | Tools declared in `uses:` resolve to content-addressed prefixes composed onto `PATH` |
| Shell hook (`eval "$(direnv hook bash)"`) | `eval "$(repro shell hook bash)"` (also `zsh`, `fish`, `pwsh`) activates environments on directory change with no direnv dependency |
| `direnv exec <dir> -- <cmd>` | `repro exec -- <cmd>` — run one command inside the project environment without spawning an interactive shell (the preferred form for AI agents) |
| `direnv status` | `repro dev-env export` and `repro health` |

Reprobuild also expresses concepts direnv has no equivalent for:

- **Typed tool identity** — tools resolve to exact versions recorded in
  `repro.lock`; build-action fingerprints include this identity so changing a
  tool invalidates affected actions automatically.
- **Service and task declarations** — `repro up`, `repro down`, `repro tasks`,
  and `repro run` come from the same `repro.nim` file.
- **Cross-platform parity** — identical `repro.nim` declarations work across
  Linux, macOS, and native Windows PowerShell (`repro shell hook pwsh`).

## Migration story

A repository that carries an `.envrc` delegating to a Nix flake:

```sh
# .envrc
use flake
```

migrates to `repro.nim`:

```nim
import repro_project_dsl
import repro_dsl_stdlib/foreign_env

package myapp:
  devEnv:
    useFlakeDevShell()
```

Or, when moving off the flake onto Reprobuild's catalog:

```nim
import repro_project_dsl

package myapp:
  uses:
    "nim >=2.2 <3.0"

  devEnv:
    env("DATABASE_URL", "postgres://localhost/myapp")
```

Load the native shell hook from your shell start-up file (for example
`~/.bashrc` or `~/.zshrc`) and trust the directory:

```sh
eval "$(repro shell hook zsh)"   # or bash / fish / pwsh
repro allow
```

During a gradual team migration where some contributors or CI scripts still rely
on `direnv`, generate a delegating `.envrc` shim:

```sh
repro hooks ensure --shell-direnv
```

That writes an `.envrc` delegating activation to `repro`, keeping `repro.nim`
as the single source of truth ([Keep an existing Nix flake as the environment](../../users/content/guides/environments/keep-a-nix-flake-environment.md)).

## What is gained and what differs

- **One source of truth:** the shell environment, `repro exec`, `repro build`,
  and `repro test` resolve tools from the same `repro.nim` and `repro.lock`.
- **Closure-bound trust:** `repro allow` hashes `repro.nim`, its static local
  Nim imports, `config.nims`, `nim.cfg`, and the dev-env lock; `git pull`
  changes to any of them pause auto-activation until `repro allow` is run again.
  In disposable CI containers running trusted code, set `REPRO_DEV_ENV_AUTO_ALLOW=1`.
- **Declarative over arbitrary shell:** `devEnv:` is compile-time-checked Nim
  rather than an arbitrary bash script evaluated on `cd`.
