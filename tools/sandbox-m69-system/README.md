# M69 system-scope destructive-gate Sandbox harness

A **Windows Sandbox** test harness that runs the **real-mutation halves**
of two M69 platform-e2e gates inside a disposable, fully-isolated
Windows desktop - so the gates exercise real DISM / capability /
service / VS-installer mutations with **zero risk to the host**.

This is *test instrumentation*, not a shipped feature. It was built to
close out M69 by turning the two `pending` gates into `passed`:

  * `tests/e2e/m69/t_e2e_windows_optional_feature_and_capability.nim`
    (`REPRO_M69_FEATURE_VM=1`)
  * `tests/e2e/m69/t_e2e_windows_vs_installer.nim`
    (`REPRO_M69_VSINSTALLER_VM=1`)

The non-destructive halves of both gates already pass on every host
(they exercise the pure parsers + drift logic + typed-operation
wiring); this harness only adds the host-altering scenarios.

## Why Windows Sandbox

Windows Sandbox gives a real, throwaway Windows install: every run
starts from a pristine OS, and nothing inside it can touch the host
filesystem except the single read-write OUTPUT folder. That is
exactly the disposable environment the gates' VM-gated scenarios
need: enabling/disabling Optional Features, installing a Windows
Capability, configuring a system Service, and installing VS Build
Tools are all host-altering, and several are reboot-prone.

## Hard Sandbox constraint - no reboots

A restart inside Windows Sandbox **discards the session**: the OS is
disposable, so a reboot is equivalent to terminating the run. Some
features (notably WSL via `Microsoft-Windows-Subsystem-Linux` and
`VirtualMachinePlatform`) are reboot-gated and cannot reach the
`Enabled` state inside the sandbox. The `e2e_windows_optional_feature_and_capability`
gate handles this by **splitting** the scenario into two:

  1. **Full lifecycle on a reboot-free feature** (`TelnetClient`,
     fallback `TFTP` / `SimpleTCP` if a future Sandbox image
     regresses) - enable -> observe `Enabled` -> drift -> rollback-
     disable. This exercises every state transition the driver makes;
     the driver logic is feature-agnostic, so a reboot-free feature
     exercises the same code paths.
  2. **`RestartNeeded`-reporting contract on a reboot-gated feature**
     (`VirtualMachinePlatform`, fallback WSL) - DISM is invoked, it
     signals `RestartNeeded`, the driver surfaces it via
     `ApplyResult.restartNeeded` AND the audit-log record's
     `restartNeeded` field, AND the driver does NOT auto-reboot and
     does NOT claim the feature reached `Enabled`. This is the
     contract that mattered for WSL; the in-sandbox part of it (apply
     -> RestartNeeded -> non-rebooted post-observation) IS testable.

The Capability + Service scenarios (OpenSSH server + sshd) are
reboot-free and run as one block.

## Files

| File | Runs on | Purpose |
|------|---------|---------|
| `m69-system.wsb` | host | Windows Sandbox config: mapped folders + `<LogonCommand>` |
| `provision-and-run-m69.ps1` | **in sandbox** | Stages binaries, downloads VS bootstrapper, runs both gates, captures output |
| `run-sandbox-m69-system.ps1` | host | Stages VC++ runtime DLLs, clears OUTPUT, launches sandbox, polls for `DONE`, closes it, surfaces per-gate results |
| `README.md` | -- | This file |

## ASCII-only rule

`provision-and-run-m69.ps1` runs inside the sandbox under `powershell.exe`
(**Windows PowerShell 5.1**). A `.ps1` saved as UTF-8 without a BOM is
decoded by 5.1 as the system ANSI codepage (CP-1252), not UTF-8 - so a
non-ASCII byte (em-dash, smart quote, ellipsis) in a string literal can
decode to a stray double-quote and break parsing of the entire script.
The provision script is kept pure ASCII for that reason.

## How to run

1. Source the dev shell (gives you `nim` / `gcc` / `just`):

   ```pwsh
   . D:\metacraft\env.ps1
   ```

2. Build `repro.exe` + the two gate binaries (in `reprobuild/`):

   ```pwsh
   nim c --out:build/bin/repro apps/repro/repro.nim
   Copy-Item build/repro-launcher.exe build/bin/repro-launcher.exe
   just e2e_windows_optional_feature_and_capability   # builds the gate test-bin
   just e2e_windows_vs_installer                       # builds the gate test-bin
   ```

   The runner verifies that `build/bin/repro.exe` + `sqlite3_64.dll` +
   `repro-launcher.exe` and `build/test-bin/e2e_windows_*` are present.

3. Run the host-side runner (from anywhere):

   ```pwsh
   pwsh -File D:\metacraft\reprobuild\tools\sandbox-m69-system\run-sandbox-m69-system.ps1
   ```

   A real VS Build Tools install commonly takes 30-60 minutes; the
   default poll timeout is 120 minutes (`-TimeoutMinutes 120`). Tune
   it if you only want to exercise the feature gate.

4. Read the artifacts in `D:\metacraft\sandbox-m69-system-out\`.

## Mapped-folder layout

All mappings are **read-only** except the OUTPUT folder.

| Host path | Sandbox path | Mode | Purpose |
|-----------|--------------|------|---------|
| `D:\metacraft\reprobuild\build\bin` | `C:\harness\repro-bin` | RO | built `repro.exe` + DLLs |
| `D:\metacraft\reprobuild\build\test-bin` | `C:\harness\test-bin` | RO | built gate test binaries |
| `tools\sandbox-m69-system\vcruntime` | `C:\harness\vcruntime` | RO | host VC++ 2015-2022 runtime DLLs |
| `tools\sandbox-m69-system` (this dir) | `C:\harness\scripts` | RO | this harness |
| `D:\metacraft\sandbox-m69-system-out` | `C:\harness\out` | **RW** | result artifacts + `DONE` |

The `vcruntime\` directory is **created and populated by the host
runner** (`run-sandbox-m69-system.ps1`) before each launch - it copies
the Visual C++ 2015-2022 x64 runtime DLLs from the host's own
`C:\Windows\System32`. See the VC++ runtime fidelity note below.

The in-sandbox script copies the read-only `repro.exe` and gate
binaries to writable sandbox paths before touching them; the read-only
mappings are never written.

## What the in-sandbox script does

1. **Stage A** - stage `repro.exe` + `sqlite3_64.dll` +
   `repro-launcher.exe` to `C:\harness\repro\`, and the two gate
   binaries to `C:\harness\gate-bin\`.
2. **Stage B** - deliver the Visual C++ 2015-2022 runtime DLLs into
   `C:\Windows\System32` (the M70/M76 fidelity step).
3. **Stage C** - download the VS Build Tools bootstrapper
   (`vs_BuildTools.exe`) from `aka.ms/vs/17/release/vs_buildtools.exe`
   and stage it AT THE WELL-KNOWN PATH
   `C:\Program Files (x86)\Microsoft Visual Studio\Installer\vs_installer.exe`
   so the `windows.vsInstaller` driver's `resolveVsInstaller()` finds
   it on a pristine Sandbox image. The bootstrapper accepts the same
   `install --add <workload>` argv as the resident installer (and IS
   the first-install entry point for both the resident installer and
   the requested workloads). `vswhere.exe` is downloaded next to it
   from the official Microsoft/vswhere release.
4. **Stage D** - run `e2e_windows_optional_feature_and_capability.exe`
   with `REPRO_M69_FEATURE_VM=1` and `REPRO_TEST_BIN_DIR=C:\harness\repro`
   set; capture stdout / stderr / exit code into
   `01-feature-capability-gate.txt`.
5. **Stage E** - run `e2e_windows_vs_installer.exe` with
   `REPRO_M69_VSINSTALLER_VM=1` set; capture into
   `02-vs-installer-gate.txt`. Bounded by a 60-minute timeout (VS
   install can be slow).
6. **Stage F** - write `RESULT.txt` with per-step exit codes + an
   overall verdict, then write the `DONE` sentinel **last**.

The very first thing the script does (before any heavy work) is write
the `_script-started.txt` checkpoint, so a parse-failure (no
checkpoint) is cleanly distinguishable from a slow-but-running script.

## Build on host, ship pre-built binaries into the sandbox

The sandbox does NOT carry the Nim toolchain. We build `repro.exe` and
the two gate `e2e_*.exe` test binaries on the **host** in the dev
shell, then map the build output (`build/bin` + `build/test-bin`) into
the sandbox read-only. The provision script copies them to writable
paths before running.

Rationale (same as the M70 harness): provisioning Nim/gcc inside the
sandbox would take 5-10 minutes per launch and is redundant - the
exact same binaries run identically in the sandbox once
`vcruntime140.dll` is in `System32` (the M70/M76 fidelity step). Each
gate's pure-logic half is already proven on the host; the
sandbox-only halves use the SAME exe.

## VC++ runtime fidelity

Same pattern as the M70 dotfiles-migration harness. A pristine Windows
Sandbox image ships **without** the Visual C++ 2015-2022
redistributable runtime (`vcruntime140.dll`, `vcruntime140_1.dll`,
`msvcp140.dll`, ...). The user's **real host has these DLLs system-
wide** in `C:\Windows\System32` - every developer machine does - so
the gate binaries (Nim-built via gcc, which still depends on the C++
runtime for some std-library paths) run there. In the bare sandbox
they would abort with `STATUS_DLL_NOT_FOUND`.

The fix: `run-sandbox-m69-system.ps1` copies the host's runtime DLLs
into `vcruntime\`; `m69-system.wsb` maps that directory read-only at
`C:\harness\vcruntime`; `provision-and-run-m69.ps1` Stage B copies them
into the sandbox's `C:\Windows\System32`. Fast (5 small DLLs, seconds),
deterministic, and a faithful replica of the host's existing
system-wide runtime.

## Output artifacts

| File | Content |
|------|---------|
| `_script-started.txt` | provision-script start checkpoint (written first) |
| `_logon-heartbeat.txt` / `_logon-powershell.log` | LogonCommand + PowerShell startup output |
| `00-provision.log` | full stage-by-stage provisioning log |
| `01-feature-capability-gate.txt` | feature/capability/service gate output |
| `02-vs-installer-gate.txt` | VS Build Tools gate output |
| `RESULT.txt` | per-step exit codes + one-line verdict |
| `DONE` | sentinel - written **last**, so its presence means all artifacts are flushed |

## Robustness

- Every stage is wrapped: a failure still records diagnostics **and**
  still writes `DONE`, so the host runner never polls forever.
- A background **watchdog** inside the sandbox writes `DONE` after 110
  min if the main run wedges.
- Each gate invocation runs under its own timeout (feature gate 20
  min, VS-installer gate 60 min); a timeout kills the process tree
  (`taskkill /T /F`).
- The host runner has a 120 min default poll timeout and force-closes
  the sandbox processes when done.
- **Fast-fail**: if the provision script has not written
  `_script-started.txt` within ~6 min of the LogonCommand firing AND
  `_logon-powershell.log` shows parser-error text, the host runner
  aborts the poll immediately (exit 3) instead of burning the full
  120 min - a parse failure means the script can never run or write
  `DONE`.

## Known limitations

- A reboot-gated Optional Feature like WSL cannot reach `Enabled`
  inside the sandbox (a restart discards the session); the gate's
  `RestartNeeded`-reporting scenario covers that branch instead.
- The VS Build Tools workload payloads are multi-gigabyte; the gate
  needs networking enabled in the sandbox (`m69-system.wsb` does so).
  A slow link will push the run toward the watchdog's 110-min ceiling.
- The sandbox starts from a pristine Windows image every run - there is
  no state carried between runs (that is the point).
- Windows Sandbox must be enabled (`Containers-DisposableClientVM`
  optional feature) and the host must support nested virtualization
  if itself a VM.
