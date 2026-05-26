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
under "Windows 11 dev environment"). Microsoft does NOT advertise a
stable direct-download shortlink for this image (the old
`aka.ms/windev_VM_vhdx` shortlink now redirects to Bing). The image
**is** available via a scriptable path, just not a fixed URL:
`provision-base-vm.ps1` resolves it at runtime by fetching the
**Quick Create gallery manifest**
(`https://go.microsoft.com/fwlink/?linkid=851584`, UTF-16-LE encoded
JSON), locating the `images[]` entry named "Windows 11 dev
environment", and reading `disk.uri` from that entry. The script then
HEAD-probes the URL to confirm the body is plausibly the dev image
(Content-Length >= 5 GB) before downloading.

The downloaded artifact is a **`.zip` wrapper** that contains the
`.vhdx` plus a small marker file. The script extracts the inner
`.vhdx` to the cache path and discards the `.zip` + temp extract dir.
As of 2026-05, the live URL resolves to
`https://download.microsoft.com/.../WinDev2407Eval.HyperV.zip`
(~21.7 GB, Windows 11 v10.0.22621); the URL changes on each Microsoft
refresh, which is why the script discovers it instead of hard-coding
it.

If manifest discovery fails (network down, manifest shape changed, no
matching image entry, or the live URL HEAD probe fails), the script
STOPs with a clear message telling you to use Hyper-V Manager's Quick
Create UI manually, extract the inner `.vhdx`, and place it at the
documented cache path. The script picks up idempotently from there.

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
| `provision-base-vm.ps1` | host | One-time idempotent VM provisioning: verify Hyper-V, cache the dev VHDX, **auto-generate a 4-word passphrase and write a Panther-override `unattend.xml` into the per-VM differencing disk so OOBE runs unattended**, create the VM, uninstall VS, disable WSL/VMP, install Nim/gcc inside the VM, take `base-clean` checkpoint, install VS Build Tools, take `base-with-vs` checkpoint |
| `run-hyperv-m69-system.ps1` | host | Per-test runner: revert -> start -> stage binaries via `Copy-VMFile` -> run a gate via `Invoke-Command -VMName` -> capture output -> stop. Parameterised by `-Gate` + `-Scenario` |
| `Get-VmPassword.ps1` | host | Reads the DPAPI-sealed `vm-cred.xml` and prints the cleartext passphrase to stdout. Exit `0` on success, `2` if the cred cache is absent. Use only when you need to sign into the VM console; PSDirect-driven tooling does not need it |
| `verify-panther-write.ps1` | host | Self-test for the Panther-override mechanism. Creates a 100 MB throwaway VHDX in `$env:TEMP`, seeds it with a baked unattend, exercises the helper, re-mounts to verify, cleans up. Touches NO real harness state and is safe to run alongside a real provisioning |
| `wordlist.txt` | host | The EFF Short Wordlist 1.0 (CC-BY-3.0), 1296 words 3-5 chars each, used by `New-Passphrase` |
| `README.md` | -- | This file |

## How to run

### Provisioning is now fully unattended

`provision-base-vm.ps1` runs **end-to-end without any interactive
prompts**, including the dev VHDX's first-boot Windows OOBE. There is
no longer a "seed the cred cache" or "finish OOBE in Hyper-V Manager"
step. The only remaining human cost is the multi-GB VHDX download (and
the script picks up idempotently after an interrupted download too).

Microsoft's dev VHDX ships with a baked
`C:\Windows\Panther\unattend.xml` containing scrubbed credentials.
That file wins **priority 2** in Setup's OOBE-pass unattend search
order, well ahead of any removable read-only media (priority 6). An
earlier version of this harness shipped an `Autounattend.xml` on a
small ISO attached as a DVD - it was empirically ignored by Setup,
because the baked Panther file always won. The harness now mounts
the **per-VM differencing disk** before first boot and writes our own
`unattend.xml` to the diff disk's `\Windows\Panther\` path; our
content wins priority 2 cleanly because it's at the same priority-2
search location but inside the diff layer. The cached base VHDX is
**read-only and never modified** - the override lives only in the
per-VM diff layer.

What happens on a first run:

  1. **Auto-passphrase.** The script generates a fresh **4-word EFF
     Short Wordlist 1.0** passphrase via a cryptographic RNG
     (`System.Security.Cryptography.RandomNumberGenerator.GetInt32`,
     NOT `Get-Random`), builds a `PSCredential` for the guest's local
     `User` account, and `Export-Clixml`-seals it at
     `$env:LOCALAPPDATA\Repro\hyperv-m69\vm-cred.xml` (DPAPI-encrypted
     for the current user). The passphrase is **never printed to
     stdout**; retrieve it with `Get-VmPassword.ps1` (see below) if you
     need to sign into the VM console.
  2. **Auto-OOBE via Panther override.** The script generates an
     `unattend.xml` (specialize + oobeSystem passes; the oobeSystem
     pass creates the local Administrators account `User` with the
     auto-generated passphrase, sets `en-US` locale + UTC TZ, and
     fires `SkipMachineOOBE` / `SkipUserOOBE` plus the modern
     `Hide*` flags so every OOBE screen is suppressed). Before the
     VM is created and first-booted, the script mounts the per-VM
     differencing disk read-write, walks `Get-Disk` -> `Get-Partition`
     -> `Get-Volume` to find the largest NTFS volume (the Windows
     system volume), backs up the baked `unattend.xml` to
     `unattend.original.xml` (so a developer who later opens the VM
     can still see what Microsoft baked), writes our `unattend.xml`
     as UTF-8 *without* a BOM (matching Microsoft's own Panther
     output), then dismounts. The mount/write/dismount sequence is
     wrapped in a `try / finally` so any write failure still
     dismounts the VHD cleanly.
  3. **VHDX download.** Same flow as before - the script resolves
     the live URL via the Hyper-V Quick Create gallery manifest,
     downloads, extracts the inner `.vhdx`, and caches it. If
     manifest discovery fails the script prints a clear "do this
     manually" message and exits.
  4. **First boot.** OOBE runs unattended (~2-5 min) using the
     Panther unattend we wrote into the diff disk. Once it's done,
     `PSDirect` becomes reachable; `Wait-VmPSDirectReady` polls
     until `Invoke-Command -VMName <name> { hostname }` returns.
     There is no host-side cleanup of the unattend after OOBE - it
     lives inside the diff disk, not on host filesystem.
  5. **The rest is unchanged.** VS uninstall, WSL/VMP disable,
     OpenSSH removal, Nim+gcc install, `base-clean` snapshot, VS
     Build Tools install, `base-with-vs` snapshot.

The Panther-write helper is self-tested by `verify-panther-write.ps1`,
which exercises the full mount/write/dismount sequence against a
throwaway 100 MB VHDX in `$env:TEMP`. The self-test creates the
VHDX, seeds it with a "baked Microsoft-style" unattend, runs the
helper, re-mounts to verify both `unattend.original.xml` (the
preserved backup) and our overwritten `unattend.xml` are present and
have the expected content, then cleans up. Run it before / after
edits to `Write-PantherUnattend` to catch regressions; it does **not**
touch any real harness state, so it is safe to run alongside a real
provisioning.

### Retrieving the VM passphrase

The auto-generated passphrase is needed only for the rare case where
you want to sign into the VM console directly (Hyper-V Manager >
Connect to `repro-m69-hyperv`). PowerShell Direct (the script's
exclusive automation channel) reads the credential directly from the
DPAPI-sealed `vm-cred.xml` and never touches the cleartext.

To print the passphrase to stdout:

```pwsh
pwsh -File D:\metacraft\reprobuild\tools\hyperv-m69-system\Get-VmPassword.ps1
```

  * Exits `0` and prints the cleartext on a successful read.
  * Exits `2` and writes a single `Write-Error` to stderr if the
    cred cache is missing (run `provision-base-vm.ps1` first).

The cred file is DPAPI-sealed for the current user; the script will
refuse to import a file sealed with a different user's key.

### Running the provisioning

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
| VS Build Tools install (VCTools + MSBuildTools, fetched over Default Switch NAT) | 30-60 min |
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
    `provision-base-vm.ps1` **auto-generates** a 4-word EFF-Short
    passphrase via a cryptographic RNG and seeds both the
    DPAPI-encrypted cache at `$env:LOCALAPPDATA\Repro\hyperv-m69\vm-cred.xml`
    (via `Export-Clixml`) and the Panther-override
    `\Windows\Panther\unattend.xml` written into the per-VM
    differencing disk before first boot. Windows OOBE then creates
    the local `User` account with that passphrase on first boot;
    PSDirect logs in via SAM credential against that account. Use
    `Get-VmPassword.ps1` to retrieve the cleartext if you need it
    for the console.
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
  * **VS Build Tools install fetches over the network.** Step 9a's
    uninstall takes the dev VHDX's pre-baked VS layout/payload cache
    with it, so `--noWeb` (cache-only install) is NOT used by Step 12;
    the bootstrapper fetches over Default Switch NAT instead. If the
    install fails the script aborts BEFORE creating `base-with-vs`
    (avoiding a broken-state snapshot). Recovery: if a prior aborted
    run left a stale `base-with-vs` around, remove it
    (`Remove-VMSnapshot -VMName repro-m69-hyperv -Name base-with-vs`)
    or re-run with `-Force` to wipe everything before re-trying.
  * The Dev VM download URL is not a fixed shortlink - it changes
    with each Microsoft refresh and the old `aka.ms` shortlink now
    redirects to Bing. The script resolves it at runtime from the
    Quick Create gallery manifest (UTF-16 JSON at
    `https://go.microsoft.com/fwlink/?linkid=851584`). If manifest
    discovery fails (network down, manifest shape changed, or
    `Windows 11 dev environment` entry absent), the script tells you
    exactly which file to extract and drop at
    `D:\metacraft\hyperv-m69-system-cache\windows-11-dev-env.vhdx`
    before re-running.
  * The harness assumes the host is x64. ARM64 Windows hosts can run
    Hyper-V but the Dev VM image is x64; that combination has not
    been validated.
  * **Panther unattend persists the passphrase in cleartext inside
    the VM's diff disk.** The auto-OOBE `unattend.xml` must contain
    `<Password>` in plaintext for Windows to consume it. Our content
    is written to the per-VM differencing disk at
    `\Windows\Panther\unattend.xml` before first boot, which is
    where Microsoft's own baked unattend would have lived. After
    OOBE completes the file remains in the diff disk - a developer
    who later opens the VM and reads
    `C:\Windows\Panther\unattend.xml` sees the passphrase in
    cleartext (and the original Microsoft-baked content backed up to
    `C:\Windows\Panther\unattend.original.xml` next to it, for
    transparency). The DPAPI-sealed `vm-cred.xml` in
    `$env:LOCALAPPDATA\Repro\hyperv-m69\` is the only host-side
    copy. Threat model: this is a host-only **disposable** VM that
    has no shared filesystem with the host and runs against the
    Default Switch. The passphrase unlocks nothing outside the VM,
    so a plaintext copy inside the disposable diff disk is
    acceptable for our use. To delete the in-VM copy after
    provisioning, you can `Remove-Item C:\Windows\Panther\unattend.xml`
    via PSDirect once `base-clean` exists - but this is not
    automated because (a) the file is already inside a disposable
    VM and (b) Windows continues to consult Panther during certain
    servicing operations, so wiping it is not free of side effects.

### Wordlist provenance

The passphrase wordlist (`wordlist.txt`) is the **EFF Short Wordlist
1.0**, curated by the Electronic Frontier Foundation for diceware-
style passphrases. The list is CC-BY-3.0 licensed; we redistribute the
word column with a 5-line `#`-prefixed header crediting EFF + the
upstream URL.

  * 1296 canonical entries, 3-5 chars each, ASCII, no duplicates.
  * The list contains one hyphenated entry (`yo-yo`) which the
    runtime helper filters out so generated passphrases always
    tokenise cleanly on `-`. Effective pool: 1295 words.
  * Entropy: ~10.34 bits/word x 4 words = ~41 bits per passphrase.
    Adequate for a local-account password on a disposable VM where
    the host-side cred cache is DPAPI-sealed.

## Gate semantics that differ from the Sandbox harness

The gate-split (reboot-free / RestartNeeded / OpenSSH-capability)
carries over from the Sandbox harness unchanged, but a few of the
post-mutation observations are environment-dependent:

  * **WSL RestartNeeded-reporting scenario.** Inside Sandbox the
    post-mutation observation could only ever be `EnablePending` (or
    `Disabled` if DISM refused) — Sandbox can't reboot, so reaching
    `Enabled` was impossible. Inside the Hyper-V VM with Windows
    Update + reboot capability, a reboot-gated feature CAN transition
    to `Enabled` transparently (Win11 22H2 22621 + WU sometimes
    completes feature enablement without an explicit reboot — the
    servicing stack finalizes out-of-band). The gate's WSL scenario
    therefore accepts `Enabled` in its post-state set; the HARD
    contract assertions remain (`restartNeeded == true` was surfaced
    by the driver; the driver did not auto-reboot).
  * **OpenSSH capability + sshd service scenario.**
    `Add-WindowsCapability` returns synchronously but Windows takes
    additional seconds to FINALIZE the install (service registration,
    file extraction, servicing-stack finalization). The Hyper-V VM
    observed `InstallPending` immediately after the driver returned.
    The gate now POLLS `Get-WindowsCapability` for up to 120s for
    `Installed`, and then polls `Get-Service -Name sshd` for up to
    30s for the service to appear. This honestly tests "capability
    eventually installs" without papering over a real bug — a stuck
    `InstallPending` past the timeout fails the gate with the last
    observed state and a slice of the DISM event log.

## Cross-references

  * `reprobuild-specs/Destructive-Gate-Test-Environments.md` -
    approach 4 (Hyper-V VM for groups C and D).
  * `reprobuild/tools/sandbox-m69-system/README.md` - the Sandbox
    harness this one supersedes for the destructive scenarios.
  * `reprobuild/tools/wsl-m69-posix/README.md` - the structural
    precedent: provisioner + idempotent state + per-gate runner +
    `try / finally` cleanup.
