# macOS Phase-5 argv-tracing shims (Tier-2 helper)

> **Audience 1, M6 Phase-5 scaffolding.** Sister to
> [`tools/wsl-m69-posix/`](../wsl-m69-posix/) and
> [`tools/sandbox-m69-system/`](../sandbox-m69-system/). See the M6
> milestone in
> [`reprobuild-specs/Multi-OS-VM-Automation-Campaign.milestones.org`](../../../reprobuild-specs/Multi-OS-VM-Automation-Campaign.milestones.org).

## What this directory is

A *Tier-2 reprobuild-specific helper* that supplies the **list of
macOS-specific binaries** the Phase-5 gates (M7-M11) need argv-traced
when they execute inside a disposable macOS VM, and a thin Nim helper
module that vm-harness (the Tier-1 generic argv-tracing-shim-installer
primitive at `metacraft-labs/vm-harness`) consumes.

The architectural split (per the M6 milestone block):

| Tier | Where | Responsibility |
|---|---|---|
| **Tier 1** | `metacraft-labs/vm-harness` (the Nim library) | Generic argv-tracing-shim-installer primitive that knows how to wrap any named binary. Backend-agnostic. |
| **Tier 2** | `reprobuild/tools/macos-phase5-shims/` (this directory) | The macOS-specific binary list (`dscl`, `launchctl`, `defaults`, `systemsetup`, `scutil`, `brew`) and any per-binary post-processing the Phase-5 gates need. |
| **Gate** | `reprobuild/tests/e2e/macos-phase5/t_e2e_*.nim` | The actual M7-M11 destructive-half scenarios that ASSERT the argv the driver shelled out is the expected one. |

## The 6 binaries Phase-5 traces

| Binary | Used by which M6 gate | Which M7-M11 milestone consumes the trace |
|---|---|---|
| `defaults` | `t_e2e_macos_phase5_macos_system_default.nim` | M9 — `defaults read` / `defaults write` / `defaults delete` against `/Library/Preferences/*.plist`. |
| `launchctl` | `t_e2e_macos_phase5_launchd_system_daemon.nim`, `t_e2e_macos_phase5_launchd_user_agent.nim` | M10 — `launchctl bootstrap system <plist>`, `launchctl bootstrap gui/<uid> <plist>`, `launchctl bootout system/<label>`, `launchctl print system/<label>`. |
| `systemsetup` | `t_e2e_macos_phase5_os_timezone.nim` | M9 — `systemsetup -settimezone <iana>` / `systemsetup -gettimezone`. |
| `scutil` | `t_e2e_macos_phase5_os_hostname.nim` | M9 — `scutil --set ComputerName/HostName/LocalHostName` + `scutil --get`. |
| `dscl` | `t_e2e_macos_phase5_passwd_group.nim` (M6 scaffold), reused M69 `t_e2e_repro_infra_passwd_user_safe_destroy.nim` (macOS arm) | M11 — `dscl . -create /Users/<name>`, `dscl . -create /Groups/<name>`, `dscl . -read`, `dscl . -delete`. |
| `brew` | (No M6 gate — Homebrew M13 ships separately) | M13 — `brew install`, `brew install --cask`, `brew list --formula --versions`, `brew uninstall`. |

## Why a separate Tier-2 layer

The generic argv-tracing primitive in vm-harness doesn't know which
binaries reprobuild's macOS drivers shell out to — that knowledge
belongs in the reprobuild repository (per the M6 milestone's
"per-driver argv-logging shims … as Tier-2 reprobuild-specific
helpers"). Keeping the binary list here means:

  1. vm-harness stays generic (the primitive trace-installer accepts
     any binary name).
  2. The binary list and the gates that consume the traces live in
     the same repository, so a future driver addition (e.g., M13's
     `brew`) only touches `reprobuild/`.
  3. The list is discoverable from grep over `reprobuild/tests/e2e/
     macos-phase5/` for the gate-name → binary mapping.

## How the gates invoke the Tier-2 helper

The M7-M11 destructive-half blocks (sandbox-gated, run only inside a
macOS VM with the matching `REPRO_PHASE5_MACOS_*_VM=1` env var) call
into the Nim helper module `shim_inventory.nim` to:

  1. Install the argv-tracing shims via the vm-harness Tier-1
     primitive for the binaries the gate needs.
  2. Run the apply/verify/destroy steps.
  3. Read the captured argv traces and ASSERT the expected commands
     were invoked (e.g., M9's gate asserts `systemsetup -settimezone
     Europe/Sofia` appears in the trace; the negative test
     `verify_macos_env_uses_shell_profile_not_launchctl` (M8) asserts
     that `launchctl setenv` does NOT appear).

## Per-driver env vars

The env-var naming convention extends the M69 pattern. See the M6
milestone block's "Implementation Details" section for the full
table. In summary:

| Env var | Gate | Driver |
|---|---|---|
| `REPRO_M69_PASSWD_VM=1` | `t_e2e_repro_infra_passwd_user_safe_destroy.nim` (REUSED) | `passwd.user` (macOS arm via dscl already shipped) |
| `REPRO_M69_FS_VM=1` | `t_e2e_repro_infra_fs_system_file.nim` (REUSED) | `fs.systemFile` (macOS /private/etc symlink resolution) |
| `REPRO_M69_ENV_VM=1` | `t_e2e_repro_infra_env_system_variable.nim` (REUSED) | `env.systemVariable` |
| `REPRO_PHASE5_MACOS_SYSTEMDEFAULT_VM=1` | `t_e2e_macos_phase5_macos_system_default.nim` | `macos.systemDefault` |
| `REPRO_PHASE5_MACOS_LAUNCHD_VM=1` | `t_e2e_macos_phase5_launchd_system_daemon.nim` + `t_e2e_macos_phase5_launchd_user_agent.nim` | `launchd.systemDaemon` + `launchd.userAgent` |
| `REPRO_PHASE5_MACOS_FS_USERFILE_VM=1` | `t_e2e_macos_phase5_fs_user_file.nim` | `fs.userFile` (Apple-flavored `$HOME`) |
| `REPRO_PHASE5_MACOS_FS_MANAGEDBLOCK_VM=1` | `t_e2e_macos_phase5_fs_managed_block.nim` | `fs.managedBlock` |
| `REPRO_PHASE5_MACOS_ENV_USERPATH_VM=1` | `t_e2e_macos_phase5_env_user_path.nim` | `env.userVariable` + `env.userPath` |
| `REPRO_PHASE5_MACOS_SHELL_INTEGRATION_VM=1` | `t_e2e_macos_phase5_shell_integration.nim` | `shell.integration` |
| `REPRO_PHASE5_MACOS_OS_TIMEZONE_VM=1` | `t_e2e_macos_phase5_os_timezone.nim` | `osTimezone` POSIX (macOS) |
| `REPRO_PHASE5_MACOS_OS_HOSTNAME_VM=1` | `t_e2e_macos_phase5_os_hostname.nim` | `osHostname` POSIX (macOS) |
| `REPRO_PHASE5_MACOS_PASSWD_GROUP_VM=1` | `t_e2e_macos_phase5_passwd_group.nim` | `passwd.group` (M11 adds the macOS dscl arm) |
