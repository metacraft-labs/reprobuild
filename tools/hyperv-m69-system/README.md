# M69 system-scope destructive-gate Hyper-V harness

A **Hyper-V VM** test harness that runs the **real-mutation halves** of
the two M69 Windows destructive gates inside a disposable, snapshot-
revertable Windows guest - so the gates exercise real DISM /
Optional-Feature / Capability / Service / VS-Build-Tools mutations
against a real Windows install (with Windows Update access, persistent
disk, and reboot capability) - all with **zero risk to the developer
host**.

This is *test instrumentation*, not a shipped feature. It exists to
close out M69 by turning the two `pending` Windows gates into `passed`:

  * `tests/e2e/m69/t_e2e_windows_optional_feature_and_capability.nim`
    (`REPRO_M69_FEATURE_VM=1`)
  * `tests/e2e/m69/t_e2e_windows_vs_installer.nim`
    (`REPRO_M69_VSINSTALLER_VM=1`)

The non-destructive halves of both gates already pass on every host
(the pure parsers + drift / strict / membership-diff logic + the typed-
operation wiring). This harness only adds the host-altering scenarios.

## Why Hyper-V (and not Sandbox)

The Sandbox harness in `tools/sandbox-m69-system/` is structurally
sound but environmentally blocked - see
`reprobuild-specs/Destructive-Gate-Test-Environments.md` (sections 2a /
2b / 2c) for the empirical record. The three Sandbox ceilings the
Windows destructive gates hit are:

  * **DISM payload fetch fails** - Sandbox isolates Windows Update.
    Features that ship as `DisabledWithPayloadRemoved` (TelnetClient
    among them) cannot reach `Enabled` because DISM cannot pull
    payloads. Error `0x80072ee6` on every fallback candidate.
  * **VS Build Tools install is too big** - pristine Sandbox has no
    persistent disk; every run re-downloads multi-GB workloads.
    Sandbox's "fast, disposable test loop" premise is gone past about
    an hour, and our 60 min ceiling timed out.
  * **No reboots** - a restart inside Sandbox terminates the session.
    Features that need a reboot (WSL, VMP) can only be observed in
    `RestartNeeded` state, never `Enabled`.

A Hyper-V VM solves all three: real Windows Update access (full
network stack inside the guest), persistent disk via snapshot
revert (the VS workloads + cache survive across runs of the same
snapshot), and reboot-capable (`Restart-VM` -> the VM comes back, and
we poll `Invoke-Command -VMName` until it's ready again).

## Base image: Microsoft's Windows 11 Dev VM (VHDX)

We use Microsoft's official **Windows 11 development-environment**
VHDX as the starting image. Two reasons:

  * Licensed and pre-activated for development use.
  * Ships with most of the apparatus we need (PowerShell Direct
    integration services, OpenSSH client, an empty user) but ships
    Visual Studio + WSL pre-installed - which our two-snapshot story
    explicitly removes to get a clean baseline. The pre-install is a
    convenient way to verify what an `Uninstall` path looks like.

URL: <https://developer.microsoft.com/windows/downloads/virtual-machines/>
(the same VHDX is reachable via the **Hyper-V Quick Create** gallery
under "Windows 11 dev environment"). Microsoft sometimes only exposes
this image via the Quick Create UI, with no scriptable direct
download URL - if that's the case at run time, `provision-base-vm.ps1`
will STOP with a clear message telling you to obtain the VHDX
manually and place it at the documented cache path. The script picks
up from there idempotently.

The VHDX is **20-50 GB**. Cache it at
`D:\metacraft\hyperv-m69-system-cache\windows-11-dev-env.vhdx` so it
is not re-downloaded.

## The two-snapshot story

We take **two** Hyper-V checkpoints of the provisioned VM. Each
destructive scenario is routed at run-time to whichever snapshot
gives it the right baseline:

| Snapshot | Baseline state | Used by |
|---|---|---|
| `base-clean` | VS uninstalled, WSL + VMP optional features disabled, OpenSSH server capability absent, sshd service absent | feature-capability gate (all sub-scenarios); vs-installer gate's **fresh-install** sub-scenario |
| `base-with-vs` | `base-clean` + VS Build Tools installed via the project's `windows.vsInstaller` driver with the workloads the gate's fixture expects | vs-installer gate's **detect-and-modify / drift / strict** sub-scenarios (future expansion - see "Deviation" note below) |

Each per-test run does `Restore-VMCheckpoint -Name <snapshot>` ->
`Start-VM` -> wait for `Invoke-Command -VMName` to succeed ->
`Copy-VMFile` binaries in -> run the gate -> capture output ->
`Stop-VM -TurnOff`. The snapshot revert is fast (seconds to tens of
seconds depending on VHD differencing-disk size); the gate run is
bounded by the gate's own internal timeout.

### Deviation: vs-installer gate's current VM scenario

The current vs-installer gate
(`t_e2e_windows_vs_installer.nim`) has ONE VM-only scenario: a fresh
install of `BuildTools` with VCTools + MSBuildTools to `C:\BuildTools`,
followed by a `classifyDrift == vsdInSync` check. That maps to
`base-clean`, NOT `base-with-vs`. The `base-with-vs` snapshot is
provisioned anyway so the harness is ready for future detect-and-
modify / drift / strict scenarios that the spec contemplates - they
can be added to the gate without changing the harness, just by passing
`-Scenario base-with-vs` to `run-hyperv-m69-system.ps1`. The README's
two-snapshot table reflects the spec intent; the runner's current
default for `-Gate vs-installer` is `-Scenario base-clean`.

## Files

| File | Runs on | Purpose |
|---|---|---|
| `provision-base-vm.ps1` | host | One-time idempotent VM provisioning: verify Hyper-V, cache the dev VHDX, create the VM, uninstall VS, disable WSL/VMP, install Nim/gcc inside the VM, take `base-clean` checkpoint, install VS Build Tools, take `base-with-vs` checkpoint |
| `run-hyperv-m69-system.ps1` | host | Per-test runner: revert -> start -> stage binaries via `Copy-VMFile` -> run a gate via `Invoke-Command -VMName` -> capture output -> stop. Parameterised by `-Gate` + `-Scenario` |
| `README.md` | -- | This file |

## How to run

### One-time: provision the VM

```pwsh
. D:\metacraft\env.ps1
pwsh -File D:\metacraft\reprobuild\tools\hyperv-m69-system\provision-base-vm.ps1
```

Wall-clock budget for a cold first run:

| Step | Time |
|---|---|
| VHDX download (20-50 GB) | 20-60 min depending on link |
| VM creation + first boot | ~5 min |
| VS uninstall + WSL/VMP disable + cleanup reboot | ~15-30 min |
| Nim + gcc provisioned inside the VM | ~5 min |
| `base-clean` checkpoint | <1 min |
| VS Build Tools install (VCTools + MSBuildTools) | 30-60 min |
| `base-with-vs` checkpoint | <1 min |

Total: ~2-4 hours, mostly download + VS install. The script is
idempotent: every step checks for prior progress and skips if done.
A re-launch after an interruption resumes from where it stopped.

### Per-test: run a gate

The gate file determines which env var the harness sets inside the VM.
The `-Scenario` parameter determines which snapshot the harness reverts
to first.

```pwsh
. D:\metacraft\env.ps1
# Build host-side binaries first (same as the Sandbox harness):
nim c --out:build/bin/repro apps/repro/repro.nim
Copy-Item build/repro-launcher.exe build/bin/repro-launcher.exe
just e2e_windows_optional_feature_and_capability
just e2e_windows_vs_installer

# Run the feature/capability gate against the clean snapshot:
pwsh -File D:\metacraft\reprobuild\tools\hyperv-m69-system\run-hyperv-m69-system.ps1 `
  -Gate feature-capability -Scenario base-clean

# Run the vs-installer gate against the clean snapshot (fresh install):
pwsh -File D:\metacraft\reprobuild\tools\hyperv-m69-system\run-hyperv-m69-system.ps1 `
  -Gate vs-installer -Scenario base-clean
```

Each invocation writes its artifacts to
`D:\metacraft\hyperv-m69-system-out\<gate>-<scenario>\` and the
top-level `RESULT.txt` + `DONE` sentinel.

## How the runner works

`run-hyperv-m69-system.ps1` is wrapped in a `try { ... } finally { ... }`
that always stops the VM (never `Save-VM`: a saved-state revert would
desync the snapshot). The lifecycle:

  1. **Revert** to the named snapshot (`Restore-VMCheckpoint`).
  2. **Start** the VM and poll until PowerShell Direct is ready
     (`Invoke-Command -VMName <name> { hostname }` succeeds).
  3. **Stage** the gate binary + `repro.exe` + `sqlite3_64.dll` +
     `repro-launcher.exe` into `C:\harness\` inside the VM via
     `Copy-VMFile` (the integration-services file-copy channel).
  4. **Run** the gate via `Invoke-Command -VMName`, setting the
     appropriate VM env var (`REPRO_M69_FEATURE_VM=1` or
     `REPRO_M69_VSINSTALLER_VM=1`) and `REPRO_TEST_BIN_DIR=C:\harness\repro`.
     Capture stdout / stderr / exit.
  5. **Write artifacts** to the host's per-test output dir:
     `01-<gate>-build.log` (skipped - host pre-builds), `02-<gate>-run.txt`,
     `RESULT.txt`, then the `DONE` sentinel **last**.
  6. **Stop** the VM (`Stop-VM -TurnOff -Force`). The snapshot remains
     untouched; the per-run mutations evaporate.

## PowerShell Direct (no SSH, no networking acrobatics)

The harness talks to the VM exclusively through Hyper-V's
**PowerShell Direct** (`Invoke-Command -VMName`) + **Copy-VMFile**.
This needs:

  * The VM's "Guest Service Interface" integration service enabled
    (the Microsoft Dev VM ships with it on; the provision script
    verifies).
  * Local credentials for an Administrator account in the guest.
    The Dev VM ships with a default `User` account and we use that;
    the provision script captures the credential as a `PSCredential`
    cached at `$env:LOCALAPPDATA\Repro\hyperv-m69\vm-cred.xml` (via
    `Export-Clixml`, encrypted with DPAPI for the current user).
  * No host networking changes - PowerShell Direct works over the
    VMBus, not over IP. The VM still has Internet (we want Windows
    Update + the VS bootstrapper download), via whichever virtual
    switch is configured (Default Switch on stock Hyper-V).

## Host-safety guarantees

  * Every DISM mutation, every `Add-WindowsCapability`, every
    `Set-Service`, every VS Build Tools install runs **inside the VM
    only** - the developer host's optional features, capabilities,
    services, and Programs-and-Features are never touched.
  * The host's filesystem is only ever modified inside three scoped
    directories:
      `D:\metacraft\hyperv-m69-system-cache\` (cached VHDX + Nim
                                              tarball + VS bootstrapper)
      `D:\metacraft\hyperv-m69-system-vhds\`  (the VM's own VHDs +
                                              differencing disks)
      `D:\metacraft\hyperv-m69-system-out\`   (gate result artifacts)
  * The harness creates exactly **one** VM, named `repro-m69-hyperv`.
    Other VMs on the host are never queried, started, stopped, or
    altered. The script verifies on every run that this is the only
    VM the harness touches.
  * No real DISM, no real VS install, no real service change happens
    on `eli-pc`. Every mutation is bounded to the VM lifecycle.

## Idempotence

`provision-base-vm.ps1` performs each step only if its post-condition
is not already satisfied:

  * VHDX already at cache path -> skip download
  * VM already exists -> skip create
  * Guest Service Interface already enabled -> skip
  * VS already uninstalled inside the guest -> skip uninstall
  * WSL + VMP optional features already disabled -> skip
  * `base-clean` snapshot already exists -> skip the clean-checkpoint step
  * VS Build Tools already installed inside the guest (per `vswhere`) ->
    skip install
  * `base-with-vs` snapshot already exists -> skip the VS-checkpoint step

A re-launch after a timeout / SIGINT resumes at the first
not-yet-satisfied step. A re-launch with both snapshots present is a
no-op (proves provisioning is done).

`run-hyperv-m69-system.ps1` always clears its own per-test output
sub-directory at the start, so partial artifacts from a prior run do
not contaminate the result.

## Output artifacts

Per-test (under `D:\metacraft\hyperv-m69-system-out\<gate>-<scenario>\`):

| File | Content |
|------|---------|
| `_run-started.txt` | runner start checkpoint (written first) |
| `00-vm-state.log` | `Get-VM`, `Get-VMSnapshot`, `Get-VMIntegrationService` snapshots before + after the run |
| `02-<gate>-run.txt` | gate stdout/stderr + exit code (the destructive scenario's full output) |
| `RESULT.txt` | per-step status + per-gate exit code + one-line verdict |
| `DONE` | sentinel - written **last** so its presence means everything else flushed |

## Hard prerequisites

  * **Hyper-V Windows Optional Feature** must be enabled on the host
    (`Microsoft-Hyper-V-All`). This is an admin-only feature that
    requires a host reboot to install; the harness will NOT enable it
    automatically. If the harness detects Hyper-V is disabled,
    `provision-base-vm.ps1` STOPs with a clear message asking the
    user to enable Hyper-V (admin PowerShell:
    `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All`,
    then reboot). This is the only manual host-side change the
    harness ever requires.
  * **Default Switch** (or a user-created external/internal virtual
    switch) must exist - needed so the VM has Internet access for
    Windows Update + the VS bootstrapper. The provision script picks
    the Default Switch if present, otherwise prompts.
  * **Disk space**: budget ~80 GB free under `D:\metacraft\` for the
    cached VHDX (20-50 GB) + the VM's working VHDs and differencing
    disks (~20-30 GB) + the result artifacts (small).

## Known limitations

  * First-run wall-clock is hours, not minutes. After provisioning, a
    per-gate run is seconds-to-minutes (snapshot revert + boot + gate
    run + shutdown).
  * The Dev VM's pre-installed VS / WSL is removed by the script, but
    the dev VM image itself still contains a snapshot of all the
    other Visual Studio Build Tools content. We rely on the
    `Uninstall` path leaving the disk in a `vswhere`-clean state -
    verified after each uninstall step.
  * Microsoft sometimes only exposes the Dev VM via Hyper-V Quick
    Create rather than a direct URL. If the canonical URL doesn't
    resolve, the script tells you exactly which file to drop at
    `D:\metacraft\hyperv-m69-system-cache\windows-11-dev-env.vhdx`
    before re-running.
  * The harness assumes the host is x64. ARM64 Windows hosts can run
    Hyper-V but the Dev VM image is x64; that combination has not
    been validated.

## Cross-references

  * `reprobuild-specs/Destructive-Gate-Test-Environments.md` -
    approach 4 (Hyper-V VM for groups C and D).
  * `reprobuild/tools/sandbox-m69-system/README.md` - the Sandbox
    harness this one supersedes for the destructive scenarios. The
    gate-split (reboot-free / RestartNeeded / OpenSSH-capability)
    carries over unchanged.
  * `reprobuild/tools/wsl-m69-posix/README.md` - the structural
    precedent: provisioner + idempotent state + per-gate runner +
    `try / finally` cleanup.
