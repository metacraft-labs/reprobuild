# Sandbox Migration Harness (M70)

A **Windows Sandbox** test harness that runs the real `repro home apply`
dotfiles migration inside a disposable, fully-isolated Windows desktop -
so migration bugs surface with **zero risk to the host**.

This is *test instrumentation*, not a shipped feature. It was built to
iterate the M70 milestone (replacing the user's real `~/dotfiles` Windows
workflow with `repro home apply` management).

## Why Windows Sandbox

The in-process M70 gate (`tests/e2e/dotfiles-replacement/`) isolates
`$HOME` / state-dir / store-root into temp directories. It never exercised:

- a **pre-populated `$HOME`** with the symlinks `bin/home-switch.ps1`
  already created (the "existing correct symlink -> cache-hit" path),
- **real registry / PATH** side-effects,
- a clean Scoop install from scratch.

Windows Sandbox gives a real, throwaway Windows install: every run starts
from a pristine OS, and nothing inside it can touch the host filesystem
except the single read-write OUTPUT folder.

## Files

| File | Runs on | Purpose |
|------|---------|---------|
| `migration.wsb` | host | Windows Sandbox config: mapped folders + `<LogonCommand>`. |
| `provision-and-migrate.ps1` | **in sandbox** | Provisions a realistic `$HOME`, runs the migration, captures artifacts. |
| `run-sandbox-migration.ps1` | host | Clears OUTPUT, launches the sandbox, polls for `DONE`, closes it. |
| `README.md` | -- | This file. |

## ASCII-only rule

`provision-and-migrate.ps1` runs inside the sandbox under `powershell.exe`
(**Windows PowerShell 5.1**). A `.ps1` saved as UTF-8 **without a BOM** is
decoded by 5.1 as the system ANSI codepage (CP-1252), not UTF-8 - so a
non-ASCII byte (em-dash, smart quote, ellipsis) in a string literal can
decode to a stray double-quote and break parsing of the entire script.
**All harness files are kept pure ASCII** so they parse identically under
every codepage. After editing, verify zero bytes > 0x7F remain.

## How to run

1. Build `repro` (from the dev shell - `. D:\metacraft\env.ps1`):

   ```pwsh
   nim c --out:build/bin/repro apps/repro/repro.nim
   Copy-Item build/repro-launcher.exe build/bin/repro-launcher.exe
   ```

   `build/bin/` must contain `repro.exe`, `sqlite3_64.dll`, and
   `repro-launcher.exe`. `sqlite3_64.dll` is loaded at runtime by the
   local store; `repro-launcher.exe` is copied next to each materialized
   launcher (apply pipeline step 9).

2. Run the host-side runner:

   ```pwsh
   pwsh -File tools/sandbox-migration/run-sandbox-migration.ps1
   ```

3. Read the artifacts in `D:\metacraft\sandbox-migration-out\`.

## Mapped-folder layout

All mappings are **read-only** except the OUTPUT folder.

| Host path | Sandbox path | Mode | Purpose |
|-----------|--------------|------|---------|
| `D:\metacraft\reprobuild\build\bin` | `C:\harness\repro-bin` | RO | built `repro.exe` + DLLs |
| `C:\Users\zahary\dotfiles` | `C:\harness\dotfiles-src` | RO | real user dotfiles |
| `C:\Users\zahary\scoop\cache` | `C:\harness\scoop-cache` | RO | Scoop download cache (fast installs) |
| `C:\Users\zahary\scoop\buckets` | `C:\harness\scoop-buckets` | RO | Scoop bucket dirs (main + extras) |
| `C:\Users\zahary\scoop\apps` | `C:\harness\scoop-apps` | RO | Scoop installed-app trees (fallback) |
| `tools\sandbox-migration\vcruntime` | `C:\harness\vcruntime` | RO | host VC++ 2015-2022 runtime DLLs |
| `D:\metacraft\reprobuild\tools\sandbox-migration` | `C:\harness\scripts` | RO | this harness |
| `D:\metacraft\sandbox-migration-out` | `C:\harness\out` | **RW** | result artifacts + `DONE` |

The `vcruntime\` directory is **created and populated by the host runner**
(`run-sandbox-migration.ps1`) before each launch - it copies the Visual C++
2015-2022 x64 runtime DLLs from the host's own `C:\Windows\System32`. See the
VC++ runtime fidelity note below.

The in-sandbox script copies the read-only `dotfiles` and `repro.exe` to
**writable** sandbox paths before touching them, so the read-only mappings
are never written.

## What the in-sandbox script does

1. **Stage A** - copy `dotfiles` -> `C:\Users\WDAGUtilityAccount\dotfiles`.
2. **Stage B** - install Scoop (`get.scoop.sh`), then copy the host's
   `main` + `extras` bucket directories DIRECTLY into the sandbox Scoop's
   `buckets\` dir (junction-aware `robocopy /E /XJ`) instead of
   `scoop bucket add` over the network - the prior network clone was
   flaky and left the extras-bucket apps unresolvable (M75 fidelity
   fix). Then register the buckets with `scoop bucket add <name>
   <localdir>` and seed the Scoop cache from the mapped host cache.
   Finally, deliver the **Visual C++ 2015-2022 runtime** by copying the
   host's runtime DLLs (mapped read-only at `C:\harness\vcruntime`) into
   the sandbox's `C:\Windows\System32` - see the VC++ fidelity note below
   (M76 fidelity fix).
3. **Stage C** - install the 14 packages the migration profile
   (`home.nim`) declares. Primary: `scoop install` (each under a bounded
   per-app timeout, retried once). Fallback for any app that still does
   not install: copy the host's already-installed `apps\<app>\<version>`
   tree in (`robocopy /E /XJ`), recreate the `current` junction, and
   `scoop reset`. Target: all 14 installed and `scoop list`-visible.
4. **Stage D** - recreate the pre-existing symlinks `bin/home-switch.ps1`
   creates (`~/.gitconfig`, org `*.gitconfig`, `~/.ssh/config`,
   `~/.ssh/config.d`) pointing at the writable dotfiles copy - so the
   migration hits the "existing correct symlink -> cache-hit" path.
5. **Stage E** - copy `repro.exe` (+ DLLs) to a writable path.
6. **Stage F** - run, capturing stdout/stderr/exit to OUTPUT:
   - `01-plan.txt`   - `repro home apply --profile-dir <copy> --plan`
   - `02-apply.txt`  - `repro home apply --profile-dir <copy>`
   - `03-replan.txt` - `--plan` again (idempotency)
7. **Stage G** - capture post-state: recursive `$HOME` listing (with
   symlink/junction targets), `%LOCALAPPDATA%\repro` tree, `scoop list`.
8. **Stage H** - write `RESULT.txt`, then the `DONE` sentinel **last**.

The very first thing the script does (before any heavy work) is write the
`_script-started.txt` checkpoint, so a parse-failure (no checkpoint) is
cleanly distinguishable from a slow-but-running script.

## VC++ runtime fidelity (M76)

A pristine **Windows Sandbox** image ships **without** the Visual C++
2015-2022 redistributable runtime (`vcruntime140.dll`, `vcruntime140_1.dll`,
`msvcp140.dll`, ...). The user's **real host has these DLLs system-wide** in
`C:\Windows\System32` - every developer machine does - so MSVC-linked tools
installed by Scoop (`codex.exe`, `nvim.exe`) run there. In the bare sandbox
the Scoop adapter's post-install probe (`<tool> --version`) aborts with exit
`-1073741515` (`0xC0000135` = `STATUS_DLL_NOT_FOUND`), failing `repro home
apply` at step 7. **This is a sandbox-fidelity gap, not a Reprobuild bug** -
the real host already has the runtime; the sandbox just lacked it.

The fix is a **fast, deterministic copy of the host's own runtime DLLs**
(it replaces a prior `scoop install vcredist` that ran Microsoft's official
installers and timed out at 600s):

1. `run-sandbox-migration.ps1` (host) copies the VC++ 2015-2022 x64 runtime
   DLLs from the host's `C:\Windows\System32` into
   `tools\sandbox-migration\vcruntime\` before launching the sandbox. The
   set: `vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll` (mandatory
   - `codex.exe`/`nvim.exe` need them), plus `msvcp140_1.dll`,
   `msvcp140_2.dll`, `concrt140.dll`, `vccorlib140.dll` if present.
2. `migration.wsb` maps `vcruntime\` into the sandbox read-only at
   `C:\harness\vcruntime`.
3. `provision-and-migrate.ps1` Stage B copies those DLLs into the sandbox's
   `C:\Windows\System32` (the sandbox account is an admin, so System32 is
   writable) and verifies `vcruntime140.dll` is present. Logged as
   `RESULT stageB_vcredist = OK/FAIL`.

Copying ~5 small DLLs takes seconds, not minutes, and it faithfully
replicates the host's existing system-wide runtime.

## Output artifacts

| File | Content |
|------|---------|
| `_script-started.txt` | provision-script start checkpoint (written first) |
| `00-provision.log` | full stage-by-stage provisioning log |
| `scoop-bootstrap.log` / `scoop-bucket.log` / `scoop-install.log` | Scoop output |
| `scoop-list.txt` | `scoop list` after installs |
| `01-plan.txt` / `02-apply.txt` / `03-replan.txt` | the three migration runs |
| `04-home-tree.txt` | recursive `$HOME` listing post-apply |
| `05-repro-state-tree.txt` | `%LOCALAPPDATA%\repro` tree post-apply |
| `06-launchers-probe.txt` | managed launcher / bin dir probe |
| `RESULT.txt` | per-step exit codes + one-line verdict |
| `DONE` | sentinel - written **last**, so its presence means all artifacts are flushed |

## Robustness

- Every stage is wrapped: a failure still records diagnostics **and** still
  writes `DONE`, so the host runner never polls forever.
- A background **watchdog** inside the sandbox writes `DONE` after 35 min if
  the main run wedges.
- Each `repro` invocation runs under its own timeout (plan 10 min, apply
  20 min); a timeout kills the process tree (`taskkill /T /F`).
- The host runner has its own 40 min poll timeout and force-closes the
  sandbox processes when done.
- **Fast-fail**: if the provision script has not written
  `_script-started.txt` within ~6 min of the LogonCommand firing AND
  `_logon-powershell.log` shows parser-error text, the host runner aborts
  the poll immediately (exit 3) instead of burning the full 40 min - a
  parse failure means the script can never run or write `DONE`.

## Known limitations

- **Host identity**: `home.nim` maps activities for host `eli-pc`; the
  sandbox host name is `WDAGUtilityAccount`'s machine. The `default`
  activity is always enabled regardless of the `hosts:` map, so the 14
  packages still plan - but `REPRO_HOST` is **not** pinned, so a profile
  that relied on a host-specific activity would behave differently here.
- **Scoop cache coverage**: only apps present in the mapped host cache are
  fast extracts; anything else downloads over the network (Networking is
  enabled for exactly this reason). GUI apps (firefox, googlechrome,
  vscode) are large and may dominate the run time.
- **`googlechrome`** is a Scoop "persist"/installer-style app and may
  require network even with a seeded cache.
- The sandbox starts from a pristine Windows image every run - there is no
  state carried between runs (that is the point).
- `repro.exe` uses `%LOCALAPPDATA%\repro` for the state dir + store (the OS
  defaults) - the harness deliberately does **not** override them, so the
  apply exercises the real default paths inside the disposable sandbox.
- Windows Sandbox must be enabled (`Windows Sandbox` optional feature) and
  the host must support nested virtualization if itself a VM.
