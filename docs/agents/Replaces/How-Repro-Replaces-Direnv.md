# How Reprobuild Replaces direnv

> **Status:** Skill-style comparison doc. Read on demand when you
> are working in a project that historically used direnv, or when
> you need to understand the rough equivalence between direnv's
> model and Reprobuild's. The canonical surfaces live in
> [`CLI/shell.md`](../CLI/shell.md), [`CLI/exec.md`](../CLI/exec.md),
> and [`CLI/hooks.md`](../CLI/hooks.md).

## What direnv does

[direnv](https://direnv.net/) is a shell extension that loads and
unloads environment variables based on the current directory:

- When the shell `cd`s into a directory that contains an `.envrc`
  (and that file is allow-listed for the user), direnv evaluates
  it in a sub-shell and exports its environment into the user's
  shell.
- When the shell leaves that directory tree, direnv restores the
  previous environment.
- The `.envrc` is a bash script with helper functions
  (`PATH_add`, `use flake`, `source_env`, `dotenv`, …) that turn
  common patterns into one-liners.

The mental model is "per-directory env-var overlay activated on
shell entry."

## Reprobuild's equivalent

Reprobuild's development-environment model is a strict superset of
direnv's env-var overlay. The surface that takes over each
direnv responsibility:

| direnv concept | Reprobuild surface |
|---|---|
| `.envrc` | Project DSL (`reprobuild.nim`) — declares tools, services, env vars, and tasks the project needs |
| `direnv allow` | Reprobuild trust is per-workspace and recorded in workspace-local metadata; no per-file allow list |
| `use flake` / `use nix` | Tool provisioning via Nix adapter (`--tool-provisioning=nix`) resolves toolchains into the environment |
| `PATH_add` | Tools declared in the project DSL produce typed binary entries; the engine composes `PATH` from realized prefixes |
| `dotenv` | Project DSL reads structured TOML/JSON config; or the DSL `env` block declares values directly |
| Shell hook (`eval "$(direnv hook bash)"`) | `repro hooks ensure --shell <bash\|zsh\|fish\|powershell>` installs a directory-entry hook that activates Reprobuild environments |
| `direnv exec <dir> -- <cmd>` | `repro exec` (see [`CLI/exec.md`](../CLI/exec.md)) — run one command inside the project environment without a sub-shell |
| `direnv status` | `repro shell --print` (env description) and `repro workspace status` (workspace-level state) |

Reprobuild also expresses concepts direnv has no equivalent for:

- **Typed tool identity** — tools are resolved to a specific binary
  with a recorded version; build-action fingerprints include this
  identity so a re-resolve to a different toolchain invalidates the
  action cache cleanly.
- **Service / process declarations** — the project DSL can declare
  long-running processes the environment supplies (typical
  `process-compose` / `devenv` territory).
- **Named tasks** — the environment exposes named commands beyond
  raw PATH lookup.
- **Lockable environment** — the resolved environment is part of
  the workspace lock, so two teammates see the same env.

## Migration story

A repository that today carries a `.envrc` like this:

```sh
# .envrc
use flake .
PATH_add ./node_modules/.bin
export DATABASE_URL=postgres://localhost/myapp
```

migrates to a Reprobuild project description like this:

```nim
# reprobuild.nim
import repro_project_dsl

package myapp:
  tools:
    nim ">=2.2"
  uses:
    nix path/to/flake
  env:
    DATABASE_URL = "postgres://localhost/myapp"
  build:
    discard
```

Then install the directory-entry hook once:

```sh
repro hooks ensure --shell zsh   # or bash/fish/powershell
```

After that, entering the project directory activates the
Reprobuild environment automatically. `.envrc` and direnv can be
removed.

If the workspace must support direnv-native consumers during a
transition (CI scripts, teammates who have not yet migrated their
shell), Reprobuild offers a compatibility shim:

```sh
repro hooks ensure --shell-direnv
```

This writes an `.envrc` that delegates to `repro shell --activate`,
so direnv still works but the canonical source of truth remains the
Reprobuild project description.

## What is gained

- **One source of truth.** The same project description drives the
  shell environment, the build, and the workspace lock. There is no
  drift between "what `.envrc` exports" and "what the build expects."
- **Reproducibility across machines.** The resolved environment is
  pinned in the workspace lock; teammates get byte-identical
  toolchain identities.
- **Build-system awareness.** Entering the directory is not just an
  env-var update; it activates the same dev-mode overrides
  (`repro develop`) the build uses, so a local source override of a
  dependency takes effect immediately.
- **Tasks and services, not just env vars.** Process orchestration
  and named tasks are part of the same description.
- **Strict-mode parsing.** The project description goes through Nim
  type checking; typos become compile errors instead of silent
  shell-script failures.

## What is lost

- **Bash scripting freedom inside the activation file.** direnv's
  `.envrc` can do arbitrary shell work; Reprobuild's project DSL
  is declarative by design (see
  [Configuration-Storage-Principles.md](../Configuration-Storage-Principles.md)
  for why). When you need an escape hatch, you write a typed Nim
  helper rather than inline bash.
- **Per-file user allow list.** direnv requires explicit
  `direnv allow` per `.envrc`. Reprobuild's trust model is
  per-workspace; once a workspace is trusted, every project under it
  is. This is a deliberate trade — workspace-scoped trust matches
  how teams actually share environments — but it differs from
  direnv's strict file-by-file consent.
- **Zero-Reprobuild support.** A teammate without Reprobuild
  installed cannot activate the environment. The compatibility shim
  above (`--shell-direnv`) preserves direnv as a fallback during a
  migration; once the team is on Reprobuild it can be retired.

## Current status

- **Implemented:** `repro shell` (manual entry into the environment),
  `repro exec` (run-one-command), `repro hooks ensure
  --shell-direnv` (writes a delegating `.envrc`). The
  tool-provisioning machinery resolves Nix / Scoop / tarball / PATH
  toolchains into the environment today.

- **Planned:** The native directory-entry shell hook
  (`repro hooks ensure --shell <shell>`) that obviates direnv
  entirely. Tracked alongside the rest of the workspace surface in
  [Workspace-Management.milestones.org](../Workspace-Management.milestones.org)
  Phase 5 ("Hooks and the publication gate"). Until then,
  `--shell-direnv` is the supported activation path.

The relationship to the broader environment model is specified in
[Workspace-And-Develop-Mode.md](../Workspace-And-Develop-Mode.md)
§"Environment Preparation"; the `repro shell` surface itself in
[`CLI/shell.md`](../CLI/shell.md).
