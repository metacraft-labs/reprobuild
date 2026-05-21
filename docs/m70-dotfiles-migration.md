# M70: Migrating the Windows `~/dotfiles` Workflow to `repro home`

This document describes the path from the existing scoop-based
`~/dotfiles` Windows workflow (driven by `bin/home-switch.ps1`) to a
Reprobuild home profile (`home.nim` + `repro home apply`). It is the
M70 deliverable that records what `home.nim` now manages, what was
deliberately deferred, and how the user retires the legacy script
incrementally.

## Starting point

The user's `~/dotfiles` repository (`C:\Users\zahary\dotfiles`) is a
Nix-flake repo with a Windows layer in `bin/home-switch.ps1`. On
Windows that script:

- installs a set of Scoop apps (`scoop install ...`),
- stow-links the `stow/` config tree into `$HOME`,
- sets up the OpenSSH server and the `sshd` service,
- decrypts GPG-managed secrets.

## What `home.nim` now manages

`home.nim` (added at the root of `~/dotfiles/`, alongside every
existing file — nothing else in the repo is moved or rewritten)
declares the **elevation-free** portion of the Windows environment:

- **Packages.** The 14 user-facing Scoop apps are listed as bare
  references inside `activity default:` under a `when windows:`
  block: `age`, `gnupg`, `git`, `gh`, `windows-terminal`, `vscode`,
  `neovim`, `pwsh`, `direnv`, `ripgrep`, `firefox`, `googlechrome`,
  `codex`, `claude-code`. `repro home apply` realizes each through
  the Scoop adapter; an app already installed at the right version
  is a cache-hit and is **not** reinstalled.
- **`7zip` is intentionally omitted.** It is a transitive Scoop
  dependency (a decompression helper Scoop itself pulls in), not a
  user-chosen package. The intent layer lists user intent; transitive
  dependencies are resolved by the package layer, so `7zip` does not
  belong in `activity default:`.
- **Git identity.** The `config:` section carries
  `git.userName = "Zahary Karadjov"` and
  `git.userEmail = "zahary@gmail.com"`, mirrored from the live
  `stow/git/.gitconfig`. `repro home set git.<key> <value>` edits
  this block in place.
- **The `stow/` tree.** Reprobuild's apply planner auto-discovers
  `~/dotfiles/stow/` and materializes every regular file under it at
  the corresponding `$HOME` path (symlink, with a junction/copy
  fallback on Windows without the symlink privilege). No file is
  hand-listed in `home.nim`; the `stow/` subtree's mere presence
  enables the behavior. The 47 files under `stow/` (git, ssh, vim,
  nvim, jj, kitty, ghostty, zsh, tmux, zellij, windows-terminal,
  ai-agents, shell-helpers, hammerspoon, nix) are materialized
  automatically.
- **The host map.** `hosts:` maps the development host (`eli-pc`) to
  the `default` activity. `default` is always enabled regardless of
  `hosts:`; the entry documents the mapping explicitly.

## Profile-declared resources (M78 extension)

M70 realized the Scoop launchers into `%LOCALAPPDATA%\repro\home\bin`
but left them off `PATH`, and the profile had no shell integration.
M78 added a `resources:` block to the `home.nim` schema; the profile
now uses it to port `home-switch.ps1`'s **elevation-free** PATH and
shell-integration affordances. The whole block is nested under a
`when windows:` predicate (these resources are Windows-specific);
`repro home apply` materializes each through the M68 resource drivers
and records one `ResourceBinding` per resource in the activation
manifest. The six declared resources:

- **`env.userPath launcherBin`** — adds `%LOCALAPPDATA%\repro\home\bin`
  (Reprobuild's realized-launcher directory — the M70 launchers are
  now reachable on `PATH`) and `%USERPROFILE%\scoop\apps\git\current\usr\bin`
  (Git-Bash `usr\bin`, so `direnv` can find `bash` — the equivalent of
  `home-switch.ps1`'s `Ensure-GitBashInPath`). The entries are written
  verbatim to `HKCU\Environment\Path`; the literal `%...%` form is
  host/user-portable and is honoured by Windows expansion when the
  PATH value is `REG_EXPAND_SZ`. The M68 `env.userPath` driver is
  non-destructive — pre-existing PATH entries survive.
- **`shell.integration powershellProfileDirenv`** — a Reprobuild-managed
  block (`repro-managed:repro-home-direnv` sentinels) in the PowerShell 7
  profile carrying the XDG base-directory setup and the direnv `cd`-hook,
  ported from `home-switch.ps1`'s `Ensure-PowerShellProfileDirenvHook`.
  The line-oriented `home.nim` surface constrains `content` to one
  logical line, so the hook is a `;`-chained PowerShell one-liner; the
  legacy block's POSIX→Windows PATH-list conversion stays in the legacy
  `# BEGIN DOTFILES DIRENV` block until the user retires it.
- **`env.userVariable` xdgConfigHome / xdgCacheHome / xdgDataHome /
  direnvConfig** — `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `XDG_DATA_HOME`,
  `DIRENV_CONFIG` as persistent `HKCU\Environment` variables
  (`expandString` / `REG_EXPAND_SZ`), matching that `home-switch.ps1`'s
  `Ensure-DirenvConfig` sets them with `SetEnvironmentVariable(...,'User')`
  — i.e. as persistent user env vars, not merely in-profile.

These resources are **additive and co-residential** with
`home-switch.ps1`: the legacy script's own versioned
`# BEGIN DOTFILES DIRENV v2` profile block, its `Ensure-GitBashInPath`
PATH entry, and its `Ensure-DirenvConfig` env-var writes all keep
working. The Reprobuild-managed block uses its own `repro-managed:`
sentinels, so the two coexist without conflict. The `env.userPath`
driver de-duplicates PATH entries that are *textually identical*, but
it does not normalize representations: on the real host the legacy
`Ensure-GitBashInPath` entry was already on `PATH` in fully-resolved
form (`C:\Users\zahary\scoop\apps\git\current\usr\bin`) while the
profile declares the same directory in `%USERPROFILE%\...` token form,
so after the re-apply that one directory is listed on `PATH` twice.
This is harmless and additive — a transition-state co-residence, not a
defect — and resolves away once the legacy `home-switch.ps1` PATH
entries are retired. The user retires the legacy
`# BEGIN DOTFILES DIRENV` block (and the corresponding PATH/XDG logic)
from `home-switch.ps1` **by hand**, once satisfied — Reprobuild never
edits the legacy script.

## What was deliberately deferred

The following parts of `home-switch.ps1` are **system scope** — they
require elevation and are outside M70's elevation-free contract:

- **OpenSSH server install + `sshd` service configuration.** These
  need `Add-WindowsCapability` / Service Control Manager access.
  They are part of the M69 system-scope catalog
  (`windows.capability`, `windows.service`). M69 is currently
  deferred; until it ships, `repro home apply --include-system` (and
  `repro infra apply`) are rejected with a structured diagnostic.
- **GPG secret decryption / `age-secrets` bootstrap.** Secret
  material handling is a separate concern from the home profile and
  is left to the existing script / a future milestone.
- **Windows Developer-Mode enablement.** `home-switch.ps1`'s
  `Ensure-DeveloperMode` writes the `HKLM\...\AppModelUnlock` registry
  flags (so non-admin symlink creation works); this needs elevation
  and is system scope. It stays in the legacy script.

`home-switch.ps1` continues to own those concerns. `home.nim` does
not attempt to replicate the script's full 1478 lines — M70 proves
the *replacement is viable* for the elevation-free surface, not that
every line is ported.

## Incremental retirement of `home-switch.ps1`

The migration is **non-destructive and co-residential**. Reprobuild
gains co-residence, not ownership:

1. **Co-existence (now).** `home.nim` is added to `~/dotfiles/`.
   `home-switch.ps1` still works exactly as before. The user runs
   `repro home apply` and the legacy script in parallel until
   confident the Reprobuild-managed state is the desired one. Where
   both contribute to the same state (PATH, a managed shell rc, an
   env var) the result is additive — duplicates are tolerated and
   visible.
2. **Retire the package-install section.** Once `repro home apply`
   reliably realizes the 14 Scoop apps, the user hand-edits
   `home-switch.ps1` to drop its `scoop install` block. This is a
   normal, user-paced edit; Reprobuild never prompts for or performs
   legacy-script deletion.
3. **Retire the stow-linking section.** Once the auto-discovered
   `stow/` materialization is trusted, the script's stow-linking
   logic is removed the same way.
4. **Retire the PATH / direnv-hook / XDG sections.** With the M78
   `resources:` block, the `env.userPath` launcher entry, the
   PowerShell-profile direnv `shell.integration` block, and the four
   XDG `env.userVariable`s are Reprobuild-owned. Once `repro home
   apply` reliably materializes them, the user hand-removes
   `home-switch.ps1`'s `Ensure-GitBashInPath`, its
   `Ensure-PowerShellProfileDirenvHook` (`# BEGIN DOTFILES DIRENV`
   block writer), and `Ensure-DirenvConfig`'s persistent-env-var
   writes. Until then the two are additive and coexist (the
   Reprobuild block uses its own `repro-managed:repro-home-direnv`
   sentinels; the `env.userPath` driver de-duplicates entries).
5. **Keep the system-scope sections** (OpenSSH, GPG secrets,
   Developer-Mode) in the script until M69 lands, then port them to a
   system profile.
6. **Retire the script entirely** only when nothing elevation-free
   or system-scope is left in it — entirely at the user's pace.

### Reprobuild-owned vs still-legacy, at a glance

| Concern | After M70 | After M78 (this extension) |
|---|---|---|
| 14 Scoop packages | Reprobuild-owned | Reprobuild-owned |
| Git identity (`config:`) | Reprobuild-owned | Reprobuild-owned |
| `stow/` config tree | Reprobuild-owned | Reprobuild-owned |
| Launcher dir on `PATH` | **legacy / unmanaged** | **Reprobuild-owned** (`env.userPath`) |
| Git-Bash `usr\bin` on `PATH` | legacy (`Ensure-GitBashInPath`) | **Reprobuild-owned** (`env.userPath`) |
| PowerShell direnv hook | legacy (`# BEGIN DOTFILES DIRENV`) | **Reprobuild-owned** (`shell.integration`) co-resident |
| XDG env vars | legacy (`Ensure-DirenvConfig`) | **Reprobuild-owned** (`env.userVariable` x4) |
| OpenSSH server + `sshd` | legacy (system scope, M69) | legacy (system scope, M69) |
| GPG secret decryption | legacy (system scope) | legacy (system scope) |
| Developer-Mode flags | legacy (system scope) | legacy (system scope) |

At no point does Reprobuild delete or rewrite a legacy file. The M70
gate (`e2e_dotfiles_replacement_on_real_host`) enforces this: it
checksums every pre-existing file in `~/dotfiles` before the run and
re-verifies each one byte-identical afterward. `home.nim` is the only
file Reprobuild authors inside the repo.

## Rollback contract

Every `repro home apply` produces a generation. `repro home rollback
<generation-id>` reverts the filesystem state (PATH contributions,
generated files, managed blocks) to that generation; Scoop apps stay
installed (rollback does not uninstall). The M70 gate captures a
baseline generation before any change and proves the rollback
round-trip works before proceeding — that is the recovery contract
that makes the migration safe to attempt autonomously.
