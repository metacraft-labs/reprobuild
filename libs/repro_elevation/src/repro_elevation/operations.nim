## The closed, typed `PrivilegedOperation` set and the
## `requiresElevation` predicate (M81 deliverable 1 + 5).
##
## Per Elevation-And-Privileged-Operations.md "The Broker Executes A
## Closed, Typed Operation Set": the broker is NOT a "run anything as
## Administrator" service. It accepts only `PrivilegedOperation`
## records — each one a typed system-scope resource operation. There
## is no code path that runs a parent-supplied arbitrary command.
##
## M81 shipped the broker MECHANISM plus two FIXTURE operation kinds
## so the M81 gate proves the mechanism end-to-end. M69 (this change)
## adds the FOUR real Windows system-scope operation kinds —
## `windows.registryValue scope=system`, `windows.optionalFeature`,
## `windows.capability`, `windows.service` — each plugging into
## `dispatch.nim` exactly the way the fixture kinds are wired. The
## set stays CLOSED and typed; there is never a parent-supplied
## arbitrary command.
##
## This module is platform-pure and unit-testable everywhere.

import std/[strutils]

import ./errors
import ./os_system_parse
import ./posix_system_parse
import ./system_value

type
  WindowsServiceRecoveryActionKind* = enum
    ## Windows-System-Resources Phase B: the four `sc.exe failure`
    ## actions a service can declare for its 1st/2nd/3rd-failure slots.
    ## The string values are the LOWER-CASE wire form used in the
    ## profile text, the codec frame, and the broker dispatch — `sc.exe
    ## failure ... actions=` consumes the same tokens (with the empty
    ## argument `""` for `wsrakNone`). The enum is the apply-side
    ## counterpart of `repro_profile.types.WindowsServiceRecoveryAction`;
    ## the two share a string vocabulary so a profile-side
    ## `WindowsServiceRecoveryAction.Restart` flows through the
    ## adapter as `"restart"` and lands here as `wsrakRestart` without
    ## a separate translation table.
    wsrakNone = "none"
    wsrakRestart = "restart"
    wsrakRunCommand = "runcommand"
    wsrakReboot = "reboot"

  ScheduledTaskScheduleKind* = enum
    ## Windows-System-Resources Phase C: apply-side counterpart of the
    ## front-end `repro_profile.types.ScheduleKind`. Same lower-case wire
    ## vocabulary so a profile-side `sskDaily` token flows through the
    ## adapter as `"daily"` and lands here as `wstskDaily` without a
    ## separate translation table. `repro_elevation` does NOT import
    ## `repro_profile` (dep-inversion) — the two enums share a wire
    ## vocabulary, not a Nim symbol.
    wstskOnBoot = "onBoot"
    wstskOnLogon = "onLogon"
    wstskOnce = "once"
    wstskDaily = "daily"
    wstskInterval = "interval"

  ScheduledTaskScheduleSpec* = object
    ## Apply-side counterpart of the front-end `ScheduleSpec` (same
    ## discriminated union, same wire vocabulary). The codec token form
    ## is `<lower-case-kind>:<payload>` matching the front-end's
    ## `encodeScheduleSpec` so a round-trip through ProfileIntent ->
    ## SystemResource -> PrivilegedOperation -> RBEB frame stays
    ## byte-stable.
    case kind*: ScheduledTaskScheduleKind
    of wstskOnBoot:
      delaySeconds*: int
    of wstskOnLogon:
      forUser*: string
    of wstskOnce:
      runAt*: string
    of wstskDaily:
      timeOfDay*: string
    of wstskInterval:
      everyMinutes*: int
      startAt*: string

  WindowsServiceRecoverySpec* = object
    ## One slot of `windows.service`'s `recoveryActions` field — an
    ## (action, delayMs) pair the SCM invokes on a failure. The
    ## sequence is positional inside the operation (1st-failure /
    ## 2nd-failure / subsequent-failure slot); `sc.exe failure ...
    ## actions=a1/d1/a2/d2/a3/d3` consumes up to three entries in
    ## declaration order.
    action*: WindowsServiceRecoveryActionKind
    delayMs*: int

  PrivilegedOperationKind* = enum
    ## The variant tag for `PrivilegedOperation`. The string form is
    ## what the RBEB protocol serializes; an unknown tag on the wire
    ## is rejected by the broker's closed-set validation.
    ##
    ## `pokFixtureFile` / `pokFixtureRegistry` are the M81 fixture
    ## kinds — their drivers write only to a sandboxed prefix or an
    ## isolated `HKLM\SOFTWARE\Reprobuild-Tests\` subkey. The real
    ## M69 system-scope kinds are added here when M69 lands.
    pokFixtureFile = "fixture.systemFile"
      ## A system-scoped file write, modelled by a write under a
      ## sandboxed prefix the gate supplies. Stands in for
      ## `fs.systemFile` under `/etc` / `${PROGRAMDATA}`.
    pokFixtureRegistry = "fixture.systemRegistry"
      ## An `HKLM` value write, confined by the driver to the
      ## `HKLM\SOFTWARE\Reprobuild-Tests\` subkey. Stands in for
      ## `windows.registryValue scope=system`.
    pokWindowsRegistryValue = "windows.registryValue"
      ## The M69 real `windows.registryValue scope=system` operation:
      ## a typed value write under `HKLM\...`. The `scope = system`
      ## marker is what partitions this into the privileged set; an
      ## `HKLM` write from a non-elevated apply is rejected before any
      ## side effect.
    pokWindowsOptionalFeature = "windows.optionalFeature"
      ## The M69 `windows.optionalFeature` operation: enable or
      ## disable a Windows Optional Feature via DISM. The driver never
      ## auto-reboots — it surfaces `RestartNeeded`.
    pokWindowsCapability = "windows.capability"
      ## The M69 `windows.capability` operation: install or uninstall
      ## a Windows Capability via `Add-WindowsCapability` /
      ## `Remove-WindowsCapability`.
    pokWindowsService = "windows.service"
      ## The M69 `windows.service` operation: manage a Windows
      ## service's start-type and runtime state. Does NOT install or
      ## remove the service itself.
    pokWindowsScheduledTask = "windows.scheduledTask"
      ## The Windows-System-Resources Phase C `windows.scheduledTask`
      ## operation: manage a Task Scheduler entry — schedule +
      ## principal + executable + enabled flag are observable live
      ## state. Apply registers the task via `Register-ScheduledTask`
      ## (on create) or `Set-ScheduledTask` (on update); destroy uses
      ## `Unregister-ScheduledTask`. Crosses the broker; per the spec
      ## §1.3 destroy is gated by `--accept-destroy`.
    pokWindowsVsInstaller = "windows.vsInstaller"
      ## The M69 Phase-B `windows.vsInstaller` operation: install /
      ## modify / uninstall a Visual Studio product through the
      ## bootstrapped installer, with workload/component membership
      ## convergence. State is read through the embedded `vswhere.exe`.
    pokWindowsFirewallRule = "windows.firewallRule"
      ## The post-M69 `windows.firewallRule` operation: manage a
      ## Windows Firewall (advfirewall) rule via the
      ## `Get-/New-/Set-/Remove-NetFirewallRule` cmdlets. Used to open
      ## a TCP/UDP port (e.g. the OpenSSH server's inbound port 22)
      ## without resorting to a parent-supplied raw command. The driver
      ## is idempotent: a re-apply with unchanged fields is a no-op.
    pokWindowsAcl = "windows.acl"
      ## The post-M83 `windows.acl` operation: manage the NTFS
      ## Discretionary Access Control List (DACL) on a file or
      ## directory via `icacls` (and optionally `takeown` for the owner
      ## change). Used to harden a sensitive directory (e.g. the
      ## per-user `.ssh` directory the M83 SSH authorized-keys helper
      ## creates) by stamping an explicit ACL and optionally disabling
      ## inheritance. The driver is idempotent: a re-apply with the
      ## same desired ACL is a no-op via the canonical-state digest.
      ## Companion of the POSIX `fs.systemFile` mode field; an NTFS
      ## directory ACL cannot be expressed as a POSIX `0700` mode and
      ## needs the typed `windows.acl` driver.
    pokMacosSystemDefault = "macos.systemDefault"
      ## The M69 Phase-C `macos.systemDefault` operation: a typed
      ## value write under `/Library/Preferences/<plist>` via
      ## `defaults`. The system-scope analogue of M68's
      ## `macos.userDefault`. Structural drift comparison; an optional
      ## `restartTarget` runs `killall <target>` when the value
      ## actually changed.
    pokSystemdSystemUnit = "systemd.systemUnit"
      ## The M69 Phase-C `systemd.systemUnit` operation: a unit file
      ## under `/etc/systemd/system/`, managed via `systemctl` (no
      ## `--user`). The system-scope analogue of M68's
      ## `systemd.userUnit`.
    pokLaunchdSystemDaemon = "launchd.systemDaemon"
      ## The M69 Phase-C `launchd.systemDaemon` operation: a plist
      ## under `/Library/LaunchDaemons/`, managed via `launchctl
      ## bootstrap/bootout system`. The system-scope analogue of
      ## M68's `launchd.userAgent`.
    pokFsSystemFile = "fs.systemFile"
      ## The M69 Phase-C `fs.systemFile` operation: a managed file
      ## under a recognized system directory (`/etc/`,
      ## `/usr/local/etc/`, `${PROGRAMDATA}`). A path outside the
      ## allowlist is rejected with an out-of-scope error.
    pokFsSystemDirectory = "fs.systemDirectory"
      ## A managed system-scope directory. The companion of
      ## `pokFsSystemFile`: same recognized-system-root allowlist
      ## (`/etc/`, `/usr/local/etc/`, `${PROGRAMDATA}`) PLUS a Windows
      ## install-root carve-out (`C:\\<top-level>`) so production
      ## profiles can declare directories like `C:\\actions-runner` or
      ## `C:\\actions-runner-tokens` without resorting to a raw
      ## elevated command. The driver creates the directory at apply
      ## time (recursively auto-creating parents) and, when
      ## `fsdAclPresent == true`, stamps the declared NTFS DACL via
      ## `icacls` in the same observe / apply cycle. `fsdDestroy`
      ## selects the rollback direction (`removeDir`).
    pokEnvSystemVariable = "env.systemVariable"
      ## The M69 Phase-C `env.systemVariable` operation: a system
      ## environment variable / system PATH with contribution-not-
      ## overwrite semantics. The system-scope analogue of M68's
      ## `env.userVariable` / `env.userPath`.
    pokPasswdUser = "passwd.user"
      ## The M69 Phase-C `passwd.user` operation: create / modify /
      ## remove a user account via `useradd` / `usermod` / `userdel`
      ## (Linux) or the macOS equivalent. The destroy direction is
      ## gated by `--accept-passwd-destroy`.
    pokOsTimezone = "os.timezone"
      ## The post-M83 cross-platform `os.timezone` operation: set the
      ## system timezone via `tzutil /s <windowsName>` on Windows
      ## (with an embedded IANA -> Windows mapping table),
      ## `timedatectl set-timezone <iana>` on Linux, and
      ## `systemsetup -settimezone <iana>` on macOS. The driver is
      ## idempotent: a re-apply with an unchanged timezone is a
      ## no-op via the canonical-state digest.
    pokOsHostname = "os.hostname"
      ## The post-M83 cross-platform `os.hostname` operation: set the
      ## system hostname via `Rename-Computer -NewName <name> -Force`
      ## on Windows (which surfaces `RestartNeeded` — Reprobuild does
      ## NOT auto-reboot), `hostnamectl set-hostname <name>` on Linux,
      ## and the triple `scutil --set ComputerName/HostName/Local
      ## HostName` invocations on macOS. The driver is idempotent: a
      ## re-apply with an unchanged hostname is a no-op.
    pokLinuxSysctl = "linux.sysctl"
      ## The post-M83 step-5 Linux `sysctl` drop-in operation: write a
      ## `<key> = <value>` line to `/etc/sysctl.d/<filename>` (mode
      ## 0644), then `sysctl -p <path>` to load the value into the
      ## live kernel. Idempotent: a re-apply with unchanged content is
      ## a no-op via the canonical-bytes digest.
    pokLinuxUdevRule = "linux.udevRule"
      ## The post-M83 step-5 Linux udev rule drop-in operation: write
      ## a rule body to `/etc/udev/rules.d/<name>.rules` (mode 0644),
      ## then `udevadm control --reload-rules`. NO automatic device-
      ## trigger — that is too invasive for a converge step.
    pokLinuxPolkitRule = "linux.polkitRule"
      ## The post-M83 step-5 Linux polkit rule drop-in operation:
      ## write a JS rule body to `/etc/polkit-1/rules.d/<name>.rules`
      ## (mode 0644). Polkit auto-reloads via inotify; no explicit
      ## reload step is needed.
    pokLinuxTmpfilesRule = "linux.tmpfilesRule"
      ## The post-M83 step-5 Linux systemd-tmpfiles drop-in operation:
      ## write a rule body to `/etc/tmpfiles.d/<name>.conf` (mode
      ## 0644), then optionally run `systemd-tmpfiles --create <path>`
      ## to apply the rule NOW (versus next boot). The `applyNow`
      ## field selects the immediate-apply behavior; it defaults to
      ## true.
    pokLinuxSudoersRule = "linux.sudoersRule"
      ## The post-M83 step-5 Linux sudoers drop-in operation: write a
      ## sudoers fragment to `/etc/sudoers.d/<name>` (NO extension —
      ## sudoers convention; mode 0440). The fragment is written to a
      ## sibling `.tmp` file first, validated with `visudo -c -f
      ## <tmp>`, and only `mv`'d into place on success. A validation
      ## failure deletes the tmp and raises a clear error — a broken
      ## sudoers file can lock the operator out of root, so the driver
      ## fails closed before the atomic rename.
    pokPasswdGroup = "passwd.group"
      ## The post-M83 step-6 Linux group operation: manage an
      ## `/etc/group` entry via `groupadd` / `groupmod` / `gpasswd`
      ## (and `groupdel` on destroy). The companion of `pokPasswdUser`.
      ## A desired `gid` is optional; when omitted the system picks
      ## one. Membership is additive-only by default — a user already
      ## in the group but not in `pgMembers` is left alone — so a
      ## profile that converges only the membership it knows about does
      ## not silently drop a manually-added admin. The destroy
      ## direction is gated by `--accept-passwd-destroy` (a removed
      ## group can break file ownership), mirroring the
      ## `pokPasswdUser` gate.
    pokLinuxNixDaemonSetting = "linux.nixDaemonSetting"
      ## The post-M83 step-6 Linux Nix-daemon configuration drop-in:
      ## write a `<key> = <value>` line to
      ## `/etc/nix/nix.conf.d/<filename>` (mode 0644). Nix re-reads
      ## its configuration on each invocation, so no daemon reload
      ## is performed — the next `nix` / `nix-daemon` call observes
      ## the new setting. The drop-in directory is created if absent.
      ## NOTE: a host whose Nix install predates drop-in support
      ## would need a managed-block region inside `/etc/nix/nix.conf`
      ## instead; that fallback is deferred until a real host
      ## surfaces the need (every supported Nix release ships the
      ## drop-in dir).
    pokSystemdSystemTimer = "systemd.systemTimer"
      ## The post-M83 step-6 systemd timer operation: a `.timer` unit
      ## under `/etc/systemd/system/`, managed via `systemctl` (no
      ## `--user`). The companion of `pokSystemdSystemUnit` — same
      ## content-digest model, same `daemon-reload` + optional
      ## `enable` workflow, with an additional runtime `state` field
      ## (`Running` / `Stopped`) that controls `systemctl start` /
      ## `systemctl stop` so a timer can be authored but held
      ## inactive when its `.service` companion is being staged.
    pokLinuxFirewallRule = "linux.firewallRule"
      ## The post-M83 step-6 Linux nftables operation: declare an
      ## `nft add rule <chain> <protocol> dport <port> <action>
      ## comment "repro-fw-<name>"` rule. The comment is the marker
      ## the observer / destroy path uses to find the rule's handle
      ## via `nft -a list chain <chain>`. Linux counterpart of
      ## `pokWindowsFirewallRule` — both manage a port-rule, the
      ## platform backend differs.
    pokLinuxNixosSystemModule = "linux.nixosSystemModule"
      ## The Dotfiles-Migration-Completion M2 NixOS escape-hatch:
      ## write a typed NixOS module fragment to
      ## `/etc/nixos/reprobuild-managed/<name>.nix`. The fragment is a
      ## verbatim Nix expression the operator pulls into
      ## `/etc/nixos/configuration.nix` via a `./reprobuild-managed.nix`
      ## glob import (the index file lists every drop-in basename and
      ## imports them as a list). Reprobuild does NOT run
      ## `nixos-rebuild switch` itself — the operator triggers the
      ## rebuild, the driver only converges the bytes. This is the
      ## "specific to NixOS hosts, but matches the existing flake model
      ## 1:1" escape-hatch the M2 spec describes; it lets every
      ## NixOS-module surface item (services.pipewire.enable,
      ## programs.hyprland.enable, etc.) flow from `system.nim` through
      ## the typed broker without recreating Nix's module evaluator.
      ## `nixosModuleDestroy` selects the rollback direction (delete
      ## the drop-in file).
    pokMacosDarwinSystemModule = "macos.darwinSystemModule"
      ## The macOS counterpart of `pokLinuxNixosSystemModule`: write a
      ## typed nix-darwin module fragment to
      ## `/etc/nix-darwin/reprobuild-managed/<name>.nix`. The operator
      ## runs `darwin-rebuild switch` separately to realise it; the
      ## driver only converges the bytes. Used for cross-OS dotfiles
      ## items the existing per-resource primitives don't cover
      ## (system.defaults.NSGlobalDomain settings beyond the
      ## `macos.systemDefault` catalog, `users.knownGroups`, the
      ## `services.*` family declared by `nix-darwin`'s module library,
      ## and the `homebrew.casks` block when the operator prefers a
      ## single declarative entry over the per-cask
      ## `pkg.homebrewCask` resources). `darwinModuleDestroy` selects
      ## the rollback direction (delete the drop-in file).
    pokLinuxFhsSandbox = "linux.fhsSandbox"
      ## The Linux-Third-Party-Sandbox-MVP M1 driver scaffold: launch a
      ## `bubblewrap` process that wraps the target binary so it sees a
      ## per-process FHS view composed from the realized package
      ## prefixes the operator named. The driver locks the M0
      ## transparency posture (see
      ## `Linux-Third-Party-Sandbox-MVP.milestones.org` M0): only
      ## `/usr / /lib / /lib64 / /bin / /sbin / /etc` come from a
      ## composed realized prefix; `/home / /tmp / /dev / /sys / /run /
      ## /var / /proc` bind-pass to the host; NO `--unshare-*` flag is
      ## set, NO `--cap-drop`, NO `--seccomp`. The user-namespace +
      ## mount-namespace bubblewrap creates are MECHANISM (the privilege
      ## needed to bind-mount without root), not an isolation policy.
    pokInlineExecCall = "reprobuild.inlineExecCall"
      ## Windows-System-Resources Phase E: the cross-cutting privileged
      ## execution of an `inlineExecCall(...)` build-graph edge tagged
      ## `requiresElevation = true`. Unlike the per-resource typed kinds
      ## above, this one carries the literal argv + tool refs + env the
      ## build engine produced for the edge; the broker is asked to
      ## spawn the process *as authored* (no per-resource convergence /
      ## observe / drift). This is the build-engine's hand-off to the
      ## broker for edges that mutate system state — the engine handles
      ## input hashing / output caching as usual; the broker handles the
      ## elevated fork only.
      ##
      ## Closed-set posture: `iecExecutable` is a closed string (no NUL
      ## byte / control character); each `iecArguments` entry is also
      ## NUL-free; `iecEnvironment` entries must match the
      ## `NAME=VALUE` shape. The `@FILE:<path>` argv substitution is
      ## applied AT EXEC TIME (the plan stores the literal token, the
      ## audit log records `<arg redacted: read from <path>>` instead
      ## of the substituted bytes). The closed-set guard fires on the
      ## literal `@FILE:<path>` form — a malformed token (`@FILE:`
      ## with no payload, or a relative path) is rejected at the
      ## codec boundary; a missing / unreadable file at exec time
      ## raises `EProtocol("@FILE: not found")`.

  PrivilegedOperation* = object
    ## A single typed operation the broker may execute. The
    ## `address` is the stable plan call-site identity (used in
    ## diagnostics and apply-log records); the variant carries the
    ## kind-specific desired state.
    address*: string
    case kind*: PrivilegedOperationKind
    of pokFixtureFile:
      ## Write `fileContent` to `fileRelPath` under the broker's
      ## sandbox prefix. `fileRelPath` MUST be a relative path with
      ## no `..` segment — the driver rejects anything else so a
      ## parent cannot escape the sandbox.
      fileRelPath*: string
      fileContent*: string
    of pokFixtureRegistry:
      ## Set `regValueName` = `regValueData` (a REG_SZ string) under
      ## `HKLM\SOFTWARE\Reprobuild-Tests\<regSubPath>`. The driver
      ## pins the `HKLM\SOFTWARE\Reprobuild-Tests\` root; `regSubPath`
      ## is appended and must not contain `..`.
      regSubPath*: string
      regValueName*: string
      regValueData*: string
    of pokWindowsRegistryValue:
      ## A typed `HKLM` registry value. `hklmSubkey` is the subkey
      ## path WITHOUT the `HKLM\` prefix (the driver pins the HKLM
      ## hive); `hklmValueName` is the value name (`""` for the
      ## default value); `hklmValueKind` + `hklmValueLiteral` carry
      ## the typed desired value. `hklmDestroy` selects the rollback
      ## direction — delete the value rather than write it.
      hklmSubkey*: string
      hklmValueName*: string
      hklmValueKind*: SystemRegistryValueKind
      hklmValueLiteral*: string
      hklmDestroy*: bool
    of pokWindowsOptionalFeature:
      ## Enable (`featureEnable == true`) or disable a Windows
      ## Optional Feature. `featureName` is the DISM feature name
      ## (e.g. `Microsoft-Windows-Subsystem-Linux`).
      featureName*: string
      featureEnable*: bool
    of pokWindowsCapability:
      ## Install (`capabilityInstall == true`) or uninstall a Windows
      ## Capability. `capabilityName` is the full capability name
      ## (e.g. `OpenSSH.Server~~~~0.0.1.0`).
      capabilityName*: string
      capabilityInstall*: bool
    of pokWindowsService:
      ## Configure a Windows service's start-type and runtime state.
      ## `serviceName` is the service short name; `serviceStartType`
      ## is one of `Automatic` / `Manual` / `Disabled`;
      ## `serviceRunning` selects the desired runtime state.
      ##
      ## Windows-System-Resources Phase B: the four optional fields
      ## below extend the operation with the service's descriptor
      ## metadata + failure-recovery policy. Each is "default = leave
      ## unmanaged"; the driver only emits the corresponding `sc.exe
      ## config` / `sc.exe failure` call when the value is non-default.
      ## A profile that doesn't set them applies byte-identically to
      ## today.
      serviceName*: string
      serviceStartType*: string
      serviceRunning*: bool
      serviceDisplayName*: string
        ## Phase B: optional `DISPLAY_NAME` to converge. Empty means
        ## "leave unmanaged" — the driver does NOT issue a
        ## `sc.exe config <name> DisplayName= ...` call.
      serviceBinPath*: string
        ## Phase B: optional `BINARY_PATH_NAME` to converge. Empty
        ## means "leave unmanaged" — the driver does NOT issue a
        ## `sc.exe config <name> binPath= ...` call.
      serviceRecoveryActions*: seq[WindowsServiceRecoverySpec]
        ## Phase B: optional failure-recovery slots. Empty seq means
        ## "leave the SCM's failure policy untouched". A non-empty
        ## seq drives `sc.exe failure <name> actions= <a1>/<d1>/...`.
      serviceRecoveryResetSeconds*: int
        ## Phase B: optional failure-count reset window. `0` means
        ## "do not emit `reset= ` to `sc.exe failure`".
    of pokWindowsScheduledTask:
      ## Windows-System-Resources Phase C: a Task Scheduler entry. The
      ## `wst*` field prefix avoids collisions with the `serviceX` /
      ## `vs*` / `fw*` families. `wstSchedule` is the discriminated
      ## trigger union (the same shape as the front-end
      ## `repro_profile.types.ScheduleSpec`); the codec serialises it
      ## as ONE canonical-text token through the existing string-list
      ## machinery. `wstDestroy` selects the rollback direction
      ## (`Unregister-ScheduledTask`), gated by `--accept-destroy`.
      wstTaskName*: string
      wstExecutable*: string
      wstArguments*: seq[string]
      wstWorkingDirectory*: string
      wstRunAsUser*: string
      wstRunWithHighestPrivileges*: bool
      wstSchedule*: ScheduledTaskScheduleSpec
      wstEnabled*: bool
      wstDestroy*: bool
    of pokWindowsVsInstaller:
      ## Converge a Visual Studio installation to the declared
      ## workload/component membership. `vsEdition` is the short
      ## edition (`Community` / `Professional` / `Enterprise` /
      ## `BuildTools`); `vsChannel` the release channel id;
      ## `vsInstallPath` the install directory; `vsWorkloads` /
      ## `vsComponents` the declared membership sets; `vsStrict`
      ## selects hard membership (remove out-of-spec workloads);
      ## `vsDestroy` selects the uninstall (rollback) direction.
      vsEdition*: string
      vsChannel*: string
      vsInstallPath*: string
      vsWorkloads*: seq[string]
      vsComponents*: seq[string]
      vsStrict*: bool
      vsDestroy*: bool
    of pokWindowsFirewallRule:
      ## Declare a Windows Firewall rule. `fwName` is the internal
      ## name (`-Name`); `fwDisplayName` the human-readable label
      ## (`-DisplayName`, defaults to `fwName`); `fwProtocol` is one of
      ## `TCP` / `UDP` / `ICMPv4` / `ICMPv6` / `Any`; `fwDirection`
      ## is `Inbound` / `Outbound`; `fwAction` is `Allow` / `Block`;
      ## `fwLocalPort` is the port number string (or `Any`), meaningful
      ## only for TCP/UDP; `fwEnabled` selects whether the rule is
      ## active. `fwDestroy` selects the rollback direction
      ## (Remove-NetFirewallRule).
      fwName*: string
      fwDisplayName*: string
      fwProtocol*: string
      fwDirection*: string
      fwAction*: string
      fwLocalPort*: string
      fwEnabled*: bool
      fwDestroy*: bool
    of pokWindowsAcl:
      ## Declare the NTFS ACL on a file or directory. `aclPath` is the
      ## absolute Windows path the ACL applies to (the driver pins this
      ## as a single closed value — no `..` segment, no shell
      ## metacharacters). `aclOwner` is an optional principal (an
      ## NTAccount form like `BUILTIN\Administrators` or a SID) that
      ## takes ownership before the grant pass; an empty string leaves
      ## ownership unchanged. `aclEntries` is the list of canonical ACE
      ## specifications in `icacls /grant` form
      ## (`<principal>:<perms>`); each one is matched against the live
      ## ACL and `icacls /grant` is invoked only on absence/diff so a
      ## re-apply is a no-op. `aclInheritanceMode` is one of `enabled`
      ## (default) / `disabled-replace` (disable + clear inherited
      ## entries) / `disabled-convert` (disable + convert inherited to
      ## explicit). `aclDestroy` selects the rollback direction —
      ## `icacls /reset` re-inherits from the parent.
      aclPath*: string
      aclOwner*: string
      aclEntries*: seq[string]
      aclInheritanceMode*: string
      aclDestroy*: bool
    of pokMacosSystemDefault:
      ## Write `sdValueLiteral` (a `defaults`-literal) for `sdKey`
      ## under `sdDomain` (a `/Library/Preferences/...` plist path,
      ## or a bare reverse-DNS domain). `sdValueType` is the
      ## `defaults` type flag (`-string` / `-bool` / `-int` / ...).
      ## `sdRestartTarget` names a daemon for `killall` on a real
      ## value change. `sdDestroy` selects the delete direction.
      sdDomain*: string
      sdKey*: string
      sdValueType*: string
      sdValueLiteral*: string
      sdRestartTarget*: string
      sdDestroy*: bool
    of pokSystemdSystemUnit:
      ## Write the unit file `suName` (a single path segment) under
      ## `/etc/systemd/system/` with `suContent`, then `daemon-reload`
      ## and optionally `enable --now`. `suDestroy` selects the
      ## disable + remove direction.
      suName*: string
      suContent*: string
      suEnabled*: bool
      suDestroy*: bool
    of pokLaunchdSystemDaemon:
      ## Write `/Library/LaunchDaemons/<sdaLabel>.plist` and
      ## `launchctl bootstrap system`. `sdaProgramArgs` is the daemon
      ## argv; `sdaRunAtLoad` is the `RunAtLoad` plist key.
      ## `sdaDestroy` selects the bootout + remove direction.
      sdaLabel*: string
      sdaProgramArgs*: seq[string]
      sdaRunAtLoad*: bool
      sdaDestroy*: bool
    of pokFsSystemFile:
      ## Write the file's content to `sfPath` — an absolute path that
      ## MUST be under a recognized system directory (`/etc/`,
      ## `/usr/local/etc/`, `${PROGRAMDATA}`). `sfDestroy` selects the
      ## delete direction.
      ##
      ## The bytes written come from exactly ONE source, selected by
      ## which of the three source fields the planner populated (the
      ## validator enforces mutual exclusion):
      ##
      ##   * `sfContent`     — inline string (the historical default,
      ##                       and the fallback when all three external-
      ##                       source fields are empty).
      ##   * `sfSourceUrl` + `sfSha256` — the controller GETs the URL,
      ##                       checks the response's BLAKE3 digest
      ##                       against `sfSha256`, raises `EProtocol`
      ##                       on mismatch, and only then asks the
      ##                       broker to write the verified bytes.
      ##   * `sfSourceLocal` — controller-side path re-read on every
      ##                       apply (so a between-step edit lands).
      ##                       Missing / unreadable raises `EProtocol`.
      sfPath*: string
      sfContent*: string
      sfSourceUrl*: string
      sfSha256*: string
      sfSourceLocal*: string
      sfDestroy*: bool
    of pokFsSystemDirectory:
      ## Create / converge / remove the managed directory `fsdPath`.
      ## `fsdAclPresent == true` triggers an `icacls` ACL stamp using
      ## `fsdAclOwner` (optional NTAccount / SID; "" leaves ownership
      ## unchanged), `fsdAclEntries` (the canonical
      ## `<principal>:<perms>` ACE specs, the same form `pokWindowsAcl`
      ## consumes), and `fsdAclInheritance` (one of `enabled` /
      ## `disabled-replace` / `disabled-convert` /
      ## `protected-clear-inherited`). `fsdDestroy` selects the
      ## rollback direction (`removeDir`). The `fsd` prefix
      ## distinguishes these fields from the `sd*` family
      ## `pokMacosSystemDefault` / `pokLaunchdSystemDaemon` already
      ## use.
      fsdPath*: string
      fsdAclPresent*: bool
      fsdAclOwner*: string
      fsdAclEntries*: seq[string]
      fsdAclInheritance*: string
      fsdDestroy*: bool
    of pokEnvSystemVariable:
      ## Contribute `evContribution` to the system variable `evName`.
      ## `evIsPathList` selects PATH-list (contribution-not-overwrite,
      ## `;`/`:` separated) semantics versus a scalar variable.
      ## `evDestroy` selects the rollback direction (subtract the
      ## contribution).
      evName*: string
      evContribution*: seq[string]
      evIsPathList*: bool
      evDestroy*: bool
    of pokPasswdUser:
      ## Create / modify / remove the user account `puName`. `puHome`
      ## / `puShell` are the pinned attributes (empty => unpinned);
      ## `puGroups` the supplementary groups. `puDestroy` selects the
      ## remove direction — gated by `--accept-passwd-destroy`.
      puName*: string
      puHome*: string
      puShell*: string
      puGroups*: seq[string]
      puDestroy*: bool
    of pokOsTimezone:
      ## Set the system timezone. `tzIana` is the IANA timezone name
      ## (`Europe/Sofia`, `America/Los_Angeles`, ...). The Windows
      ## driver maps the IANA name to a Windows timezone name via the
      ## embedded `IanaToWindowsTzTable`; the POSIX drivers use the
      ## IANA name directly. An unmapped IANA name fails closed at
      ## validation time.
      tzIana*: string
    of pokOsHostname:
      ## Set the system hostname. `hostnameName` is the desired
      ## hostname (RFC 1123 charset). The driver does NOT auto-reboot
      ## even when the host requests one; instead it surfaces
      ## `RestartNeeded` so the operator can schedule the reboot.
      hostnameName*: string
    of pokLinuxSysctl:
      ## Set a sysctl key. `sysctlKey` is the dotted key
      ## (e.g. `kernel.perf_event_paranoid`); `sysctlValue` is the
      ## desired value; `sysctlFilename` is the drop-in filename
      ## under `/etc/sysctl.d/` (must end `.conf`); `sysctlDestroy`
      ## selects the rollback direction (delete the drop-in file).
      sysctlKey*: string
      sysctlValue*: string
      sysctlFilename*: string
      sysctlDestroy*: bool
    of pokLinuxUdevRule:
      ## Write a udev rule drop-in. `udevName` is the rule basename
      ## (must end `.rules`); `udevContent` is the full file body;
      ## `udevDestroy` selects the rollback direction.
      udevName*: string
      udevContent*: string
      udevDestroy*: bool
    of pokLinuxPolkitRule:
      ## Write a polkit JS rule drop-in. `polkitName` is the rule
      ## basename (must end `.rules`); `polkitContent` is the full
      ## file body; `polkitDestroy` selects the rollback direction.
      polkitName*: string
      polkitContent*: string
      polkitDestroy*: bool
    of pokLinuxTmpfilesRule:
      ## Write a systemd-tmpfiles drop-in. `tmpfilesName` is the rule
      ## basename (must end `.conf`); `tmpfilesContent` is the full
      ## file body; `tmpfilesApplyNow` selects whether to invoke
      ## `systemd-tmpfiles --create <path>` after writing (default
      ## true); `tmpfilesDestroy` selects the rollback direction.
      tmpfilesName*: string
      tmpfilesContent*: string
      tmpfilesApplyNow*: bool
      tmpfilesDestroy*: bool
    of pokLinuxSudoersRule:
      ## Write a sudoers drop-in. `sudoersName` is the file basename
      ## (NO extension — sudoers convention); `sudoersContent` is the
      ## full fragment body. Always written 0440 to a `.tmp` file,
      ## validated with `visudo -c -f`, and `mv`'d into place on
      ## success. `sudoersDestroy` selects the rollback direction.
      sudoersName*: string
      sudoersContent*: string
      sudoersDestroy*: bool
    of pokPasswdGroup:
      ## Manage a `/etc/group` entry. `pgName` is the group name;
      ## `pgGid` is the desired numeric gid (empty => unpinned — the
      ## system picks one on create, an existing gid is left alone on
      ## update); `pgMembers` is the supplementary-membership set the
      ## resource declares. Membership is ADDITIVE-ONLY: a user
      ## already in the group but not in `pgMembers` is left alone, so
      ## a profile that converges only what it knows about does not
      ## silently drop a manually-added admin. `pgDestroy` selects the
      ## rollback direction (`groupdel`).
      pgName*: string
      pgGid*: string
      pgMembers*: seq[string]
      pgDestroy*: bool
    of pokLinuxNixDaemonSetting:
      ## Write a Nix-daemon configuration drop-in. `nixKey` is the
      ## Nix config key (e.g. `experimental-features`); `nixValue` is
      ## the value (newlines are refused — a config line is one
      ## `key = value` entry); `nixFilename` is the drop-in basename
      ## under `/etc/nix/nix.conf.d/` (must end `.conf`).
      ## `nixDestroy` selects the rollback direction (delete the
      ## drop-in file).
      nixKey*: string
      nixValue*: string
      nixFilename*: string
      nixDestroy*: bool
    of pokSystemdSystemTimer:
      ## Write the timer unit file `stName` (a single path segment
      ## ending `.timer`) under `/etc/systemd/system/` with
      ## `stContent`, then `daemon-reload` and optionally `enable`
      ## (no `--now` — the runtime state is governed by `stRunning`
      ## via a separate `start` / `stop`). `stRunning` selects
      ## whether the timer is active; an enabled but stopped timer
      ## stays armed across reboots but does not fire until the next
      ## apply flips `stRunning` to true. `stDestroy` selects the
      ## disable + remove direction.
      stName*: string
      stContent*: string
      stEnabled*: bool
      stRunning*: bool
      stDestroy*: bool
    of pokLinuxFirewallRule:
      ## Declare an nftables rule. `lfwChain` is the chain triple
      ## (e.g. `inet filter input`); `lfwName` is the stable
      ## identifier embedded in the rule's comment (the marker the
      ## observe + destroy paths look for); `lfwProtocol` is one of
      ## `tcp` / `udp` / `icmp` / `icmpv6`; `lfwDirection` is
      ## informational (`inbound` / `outbound` — the chain already
      ## names this; included for parity with the Windows surface);
      ## `lfwLocalPort` is the port number / range (required for
      ## tcp / udp; ignored for icmp / icmpv6); `lfwAction` is one
      ## of `accept` / `drop` / `reject`. `lfwDestroy` selects the
      ## delete direction (find the rule's handle, `nft delete
      ## rule <chain> handle <handle>`).
      lfwChain*: string
      lfwName*: string
      lfwProtocol*: string
      lfwDirection*: string
      lfwLocalPort*: string
      lfwAction*: string
      lfwDestroy*: bool
    of pokLinuxNixosSystemModule:
      ## Write `nixosModuleContent` to
      ## `/etc/nixos/reprobuild-managed/<nixosModuleName>` (the basename
      ## must be a single segment ending `.nix`). The fragment body is
      ## a verbatim Nix expression — typically a single attribute set
      ## `{ services.pipewire.enable = true; }` or the equivalent
      ## module function `{ ... }: { ... }`. `nixosModuleDestroy`
      ## selects the rollback direction (delete the drop-in file).
      nixosModuleName*: string
      nixosModuleContent*: string
      nixosModuleDestroy*: bool
    of pokMacosDarwinSystemModule:
      ## Write `darwinModuleContent` to
      ## `/etc/nix-darwin/reprobuild-managed/<darwinModuleName>` (the
      ## basename must be a single segment ending `.nix`). The fragment
      ## body is a verbatim Nix expression — typically an attribute set
      ## like `{ system.defaults.dock.autohide = true; }` or a module
      ## function. `darwinModuleDestroy` selects the rollback direction
      ## (delete the drop-in file).
      darwinModuleName*: string
      darwinModuleContent*: string
      darwinModuleDestroy*: bool
    of pokLinuxFhsSandbox:
      ## Launch `fsbBinPath` under bubblewrap with the M0-locked
      ## transparency-posture invocation shape:
      ##
      ##   bwrap                                                 \
      ##     --bind <fsbFhsTreeRoots[0]>/usr   /usr              \
      ##     --bind <fsbFhsTreeRoots[0]>/lib   /lib              \
      ##     --bind <fsbFhsTreeRoots[0]>/lib64 /lib64            \
      ##     --bind <fsbFhsTreeRoots[0]>/bin   /bin              \
      ##     --bind <fsbFhsTreeRoots[0]>/sbin  /sbin             \
      ##     --bind <fsbFhsTreeRoots[0]>/etc   /etc              \
      ##     --dev-bind /dev /dev                                \
      ##     --bind /home /home                                  \
      ##     --bind /tmp  /tmp                                   \
      ##     --bind /run  /run                                   \
      ##     --bind /sys  /sys                                   \
      ##     --bind /var  /var                                   \
      ##     --proc /proc                                        \
      ##     -- <fsbBinPath> <fsbArgv...>
      ##
      ## `fsbBinPath` is an absolute path inside the FHS view
      ## (typically `/usr/bin/<x>`); the parser enforces leading `/`.
      ## `fsbFhsTreeRoots` is the sequence of realized package
      ## prefixes to compose into `/usr / /lib / /lib64 / /bin /
      ## /sbin / /etc` — M1 takes the FIRST entry and binds the
      ## six sub-paths from it; M2+ adds multi-package overlay /
      ## sequential-bind composition. Each entry is validated as an
      ## absolute path at parse time (existence is deferred to apply
      ## because the realized prefix is produced upstream by the
      ## catalog-adapter chain). `fsbArgv` is the additional argv
      ## passed to the wrapped binary; argv is execve-delivered (NOT
      ## shell-parsed) so the parser rejects only NUL bytes, matching
      ## the closed-set contract.  `fsbDestroy` is the rollback flag
      ## — bubblewrap sessions are NOT persistent, so destroy is a
      ## no-op (the driver returns absent without spawning anything).
      ## Kept for parity with the other Phase-C drivers so the
      ## dispatch destroy-predicate stays uniform.
      fsbBinPath*: string
      fsbFhsTreeRoots*: seq[string]
      fsbArgv*: seq[string]
      fsbDestroy*: bool
    of pokInlineExecCall:
      ## Windows-System-Resources Phase E: the elevated execution of a
      ## `requiresElevation = true` `inlineExecCall(...)` build edge.
      ##
      ## * `iecExecutable`        — argv[0]; the program the broker
      ##                            spawns. NUL bytes are refused at the
      ##                            codec boundary; empty is refused by
      ##                            the validator.
      ## * `iecArguments`         — argv[1..]; each entry passes through
      ##                            the `@FILE:<path>` expander at the
      ##                            moment of execution (the plan stores
      ##                            the literal token).
      ## * `iecWorkingDirectory`  — optional cwd; empty means "broker's
      ##                            cwd at fork time."
      ## * `iecEnvironment`       — list of `NAME=VALUE` strings the
      ##                            broker prepends to the spawned
      ##                            process's environment.
      ## * `iecToolIdentityRefs`  — names of `uses:` tools the build
      ##                            engine resolved on the apply side;
      ##                            carried through to the broker so its
      ##                            PATH-prepending hook (mirror of the
      ##                            engine's `toolIdentityResolver`) can
      ##                            still find the right binaries.
      ## * `iecAcceptExitCodes`   — closed set of exit codes the broker
      ##                            should treat as success. Default
      ##                            `@[0]`; a longer list lets a profile
      ##                            opt into e.g. `@[0, 3010]` (the
      ##                            "operation succeeded; reboot
      ##                            required" code Windows installers
      ##                            return).
      iecExecutable*: string
      iecArguments*: seq[string]
      iecWorkingDirectory*: string
      iecEnvironment*: seq[string]
      iecToolIdentityRefs*: seq[string]
      iecAcceptExitCodes*: seq[int]

# ---------------------------------------------------------------------------
# linux.fhsSandbox — closed-set charset / shape helpers.
#
# The driver builds a `bwrap` argv vector (NOT a shell command) so per-
# argument shell-metacharacter filtering is not required. What IS
# required:
#
#   * `fsbBinPath` MUST be a POSIX absolute path (leading `/`) so the
#     bubblewrap target binary identity is unambiguous; a relative path
#     would be resolved against bubblewrap's cwd inside the FHS view,
#     which is implementation-defined and not the contract.
#
#   * Each `fsbFhsTreeRoots` entry MUST be a POSIX absolute path. The
#     driver binds `<root>/usr`, `<root>/lib`, ... so a non-absolute
#     entry has no defined meaning. Existence is deferred to apply time
#     (the catalog-adapter chain produces the prefix upstream).
#
#   * Neither field may contain a NUL byte — `execve` would refuse it
#     and the resulting EFAULT would surface as an inscrutable broker
#     failure. Reject it at parse time so the operator sees a clean
#     diagnostic.
# ---------------------------------------------------------------------------

proc isPosixAbsolutePath*(p: string): bool =
  ## True only for a non-empty path with a leading `/`. Used by the
  ## `linux.fhsSandbox` closed-set validator to enforce that the
  ## wrapped binary path and every composed FHS-tree root are
  ## absolute. The driver does NOT canonicalize the path (no `..`
  ## collapse, no symlink resolution) — that is the catalog-adapter
  ## chain's responsibility upstream — but a leading `/` is the
  ## minimum precondition for an unambiguous bind-mount target.
  if p.len == 0:
    return false
  if p[0] != '/':
    return false
  return true

proc containsNul*(s: string): bool =
  ## True if `s` contains a NUL byte (`\x00`). The closed-set
  ## validator uses this to refuse any field that would later be
  ## passed to `execve` as an argv element — the kernel rejects NUL
  ## in argv with EFAULT, and surfacing it as a typed parse error
  ## gives the operator a useful diagnostic instead of a cryptic
  ## broker failure.
  for ch in s:
    if ch == '\x00':
      return true
  return false

# ---------------------------------------------------------------------------
# Windows-System-Resources Phase E — `@FILE:<path>` argv preprocessor.
#
# Every `inlineExecCall(...)` argv entry is screened at execution time:
# a token of the form `@FILE:<path>` is replaced by the trimmed
# contents of `<path>`. The plan stores the literal `@FILE:...` (no
# secret baked into the plan); the audit log records the substitution
# as `<arg redacted: read from <path>>` so secrets never leak to logs.
#
# This helper lives in `repro_elevation` so both the broker dispatch
# path (`pokInlineExecCall`) and the build engine's non-elevated exec
# lowering (`reprobuild.builtin.exec`) call the same pure function —
# the spec mandates identical semantics on both paths.
# ---------------------------------------------------------------------------

const ArgFilePrefix* = "@FILE:"
  ## The literal prefix the argv preprocessor recognises. Spec-fixed.

proc isArgFileToken*(arg: string): bool =
  ## True when `arg` literally starts with the `@FILE:` prefix. Does
  ## NOT validate the payload — that is the validator's / expander's
  ## job; this is the cheap branch the lowering uses to skip ordinary
  ## arguments. A bare `@FILE:` (no payload) IS classified as a token
  ## here so the validator / expander catches it (it would otherwise
  ## fall through unmolested as if it were an ordinary argument).
  arg.len >= ArgFilePrefix.len and arg.startsWith(ArgFilePrefix)

proc argFilePath*(arg: string): string =
  ## Return the `<path>` portion of an `@FILE:<path>` token, or "" if
  ## `arg` is not a well-formed token. Pure — used by the validator
  ## and the expander.
  if not isArgFileToken(arg):
    return ""
  result = arg[ArgFilePrefix.len .. ^1]

proc isAbsoluteArgFilePath*(p: string): bool =
  ## Closed-set defence-in-depth: the spec doesn't pin the syntactic
  ## form, but the expander rejects RELATIVE `@FILE:<path>` tokens at
  ## apply time. "Absolute" here is the cross-platform union: POSIX
  ## leading `/` OR Windows drive-letter `X:\\...` / `X:/...`. The
  ## helper is a documented decision (see the `@FILE:` validator
  ## branch below) so a profile author who tries `@FILE:secret.tok`
  ## from a non-deterministic cwd is refused at the codec boundary
  ## with a clear diagnostic.
  if p.len == 0:
    return false
  if p[0] == '/':
    return true
  if p.len >= 3 and p[1] == ':' and (p[2] == '\\' or p[2] == '/'):
    return true
  return false

proc argFileTokenError*(arg: string): string =
  ## Returns "" when the token is well-formed, otherwise a human
  ## diagnostic the validator turns into `EProtocol`. Rejects:
  ##
  ##   * `@FILE:`              — empty payload, no path supplied.
  ##   * `@FILE:rel/path`      — relative path; the broker's cwd is
  ##                             not a guaranteed identity, so a
  ##                             relative path is non-deterministic.
  ##   * `@FILE:<…NUL…>`       — NUL byte in the path; `open` /
  ##                             `readFile` would refuse it and the
  ##                             ensuing error is inscrutable.
  ##
  ## Callers that hold a non-token argv entry MUST NOT call this —
  ## use `isArgFileToken` to dispatch first.
  if not isArgFileToken(arg):
    return "argument '" & arg & "' is not an @FILE:<path> token"
  let path = argFilePath(arg)
  if path.len == 0:
    return "@FILE: token has an empty path (expected @FILE:<path>)"
  if containsNul(path):
    return "@FILE: token path contains a NUL byte (refused — open(2) " &
      "would reject it)"
  if not isAbsoluteArgFilePath(path):
    return "@FILE: token path '" & path & "' is not absolute — " &
      "relative paths are refused because the broker's cwd is not a " &
      "stable identity (use a POSIX absolute path or a Windows " &
      "drive-letter form)"
  return ""

proc expandArgFileToken*(arg: string;
                         readPath: proc (path: string): string): string =
  ## Substitute a SINGLE `@FILE:<path>` token. Non-token args are
  ## returned unchanged. The `readPath` injection lets the broker
  ## thread its own filesystem-backed reader; tests inject a pure
  ## table-backed reader so the substitution semantics are exercised
  ## cross-platform without a real disk.
  ##
  ## Semantics:
  ##   * the trailing `\r` / `\n` of the file contents is stripped
  ##     (the spec calls for "trimmed contents"; trailing CR/LF is the
  ##     common case for text-file secrets);
  ##   * an empty file (after the trim) substitutes to an empty arg —
  ##     the downstream command decides whether that is valid;
  ##   * `readPath` failures and missing files raise `EProtocol(
  ##     "@FILE: not found at <path>: <reason>")` — the spec is
  ##     explicit on the diagnostic.
  if not isArgFileToken(arg):
    return arg
  let path = argFilePath(arg)
  # Well-formed token guard. The codec-time validator already rejects
  # malformed tokens, but defence-in-depth: we re-check here so a
  # call-site that bypassed the codec (in-process construction) still
  # fails closed.
  let tokenErr = argFileTokenError(arg)
  if tokenErr.len > 0:
    raiseProtocol("@FILE: " & tokenErr)
  var contents: string
  try:
    contents = readPath(path)
  except IOError as e:
    raiseProtocol("@FILE: not found at '" & path & "': " & e.msg)
  except OSError as e:
    raiseProtocol("@FILE: not found at '" & path & "': " & e.msg)
  # Strip a trailing newline (and CR) — the trimming the spec calls
  # out. Leading whitespace is preserved (a leading space in a token
  # file is presumably load-bearing).
  while contents.len > 0 and
        (contents[contents.high] == '\n' or contents[contents.high] == '\r'):
    contents.setLen(contents.len - 1)
  result = contents

proc expandArgFiles*(argv: openArray[string];
                     readPath: proc (path: string): string): seq[string] =
  ## Run the `@FILE:` expander across an entire argv. The order of
  ## entries is preserved; non-token args pass through unchanged.
  ## Used by both the broker dispatch path (`pokInlineExecCall`) and
  ## the engine's non-elevated `reprobuild.builtin.exec` lowering so
  ## both run the SAME expansion semantics (spec §2.1).
  result = newSeqOfCap[string](argv.len)
  for arg in argv:
    result.add(expandArgFileToken(arg, readPath))

proc auditArgvWithRedaction*(argv: openArray[string]): seq[string] =
  ## The audit-log rendering of an argv. Each `@FILE:<path>` token is
  ## replaced by `<arg redacted: read from <path>>` so the substituted
  ## contents (typically a secret) never reach the apply log. Non-
  ## token args pass through verbatim. Spec §2.1.
  result = newSeqOfCap[string](argv.len)
  for arg in argv:
    if isArgFileToken(arg):
      let path = argFilePath(arg)
      result.add("<arg redacted: read from " & path & ">")
    else:
      result.add(arg)

# ---------------------------------------------------------------------------
# requiresElevation predicate.
# ---------------------------------------------------------------------------

proc requiresElevation*(kind: PrivilegedOperationKind): bool =
  ## Static `requiresElevation` predicate keyed on the operation
  ## kind. Every `PrivilegedOperationKind` in this enum is, by
  ## construction, a privileged (system-scope) operation — the enum
  ## holds ONLY operations the planner has already partitioned into
  ## the privileged set. The predicate is kept explicit (rather than
  ## a blanket `true`) so the M69 catalog, which will add kinds whose
  ## privilege depends on a `scope` field, has the hook it needs.
  # `pokWindowsRegistryValue` is constructed by the non-elevated
  # planner ONLY for an HKLM (`scope = system`) target — an HKCU
  # value stays a home-scope M68 resource and never becomes a
  # `PrivilegedOperation`. Every kind in this enum is privileged.
  case kind
  of pokFixtureFile: true
  of pokFixtureRegistry: true
  of pokWindowsRegistryValue: true
  of pokWindowsOptionalFeature: true
  of pokWindowsCapability: true
  of pokWindowsService: true
  of pokWindowsScheduledTask: true
  of pokWindowsVsInstaller: true
  of pokWindowsFirewallRule: true
  of pokWindowsAcl: true
  of pokMacosSystemDefault: true
  of pokSystemdSystemUnit: true
  of pokLaunchdSystemDaemon: true
  of pokFsSystemFile: true
  of pokFsSystemDirectory: true
  of pokEnvSystemVariable: true
  of pokPasswdUser: true
  of pokOsTimezone: true
  of pokOsHostname: true
  of pokLinuxSysctl: true
  of pokLinuxUdevRule: true
  of pokLinuxPolkitRule: true
  of pokLinuxTmpfilesRule: true
  of pokLinuxSudoersRule: true
  of pokPasswdGroup: true
  of pokLinuxNixDaemonSetting: true
  of pokSystemdSystemTimer: true
  of pokLinuxFirewallRule: true
  of pokLinuxNixosSystemModule: true
  of pokMacosDarwinSystemModule: true
  of pokLinuxFhsSandbox: true
  of pokInlineExecCall: true

# ---------------------------------------------------------------------------
# Kind <-> string helpers (used by the RBEB codec).
# ---------------------------------------------------------------------------

proc privilegedOperationKindFromString*(s: string): PrivilegedOperationKind =
  ## Strict parse. An unrecognized tag raises — the broker's
  ## closed-set validation depends on this so an unknown frame is
  ## rejected rather than silently dispatched.
  case s
  of $pokFixtureFile: pokFixtureFile
  of $pokFixtureRegistry: pokFixtureRegistry
  of $pokWindowsRegistryValue: pokWindowsRegistryValue
  of $pokWindowsOptionalFeature: pokWindowsOptionalFeature
  of $pokWindowsCapability: pokWindowsCapability
  of $pokWindowsService: pokWindowsService
  of $pokWindowsScheduledTask: pokWindowsScheduledTask
  of $pokWindowsVsInstaller: pokWindowsVsInstaller
  of $pokWindowsFirewallRule: pokWindowsFirewallRule
  of $pokWindowsAcl: pokWindowsAcl
  of $pokMacosSystemDefault: pokMacosSystemDefault
  of $pokSystemdSystemUnit: pokSystemdSystemUnit
  of $pokLaunchdSystemDaemon: pokLaunchdSystemDaemon
  of $pokFsSystemFile: pokFsSystemFile
  of $pokFsSystemDirectory: pokFsSystemDirectory
  of $pokEnvSystemVariable: pokEnvSystemVariable
  of $pokPasswdUser: pokPasswdUser
  of $pokOsTimezone: pokOsTimezone
  of $pokOsHostname: pokOsHostname
  of $pokLinuxSysctl: pokLinuxSysctl
  of $pokLinuxUdevRule: pokLinuxUdevRule
  of $pokLinuxPolkitRule: pokLinuxPolkitRule
  of $pokLinuxTmpfilesRule: pokLinuxTmpfilesRule
  of $pokLinuxSudoersRule: pokLinuxSudoersRule
  of $pokPasswdGroup: pokPasswdGroup
  of $pokLinuxNixDaemonSetting: pokLinuxNixDaemonSetting
  of $pokSystemdSystemTimer: pokSystemdSystemTimer
  of $pokLinuxFirewallRule: pokLinuxFirewallRule
  of $pokLinuxNixosSystemModule: pokLinuxNixosSystemModule
  of $pokMacosDarwinSystemModule: pokMacosDarwinSystemModule
  of $pokLinuxFhsSandbox: pokLinuxFhsSandbox
  of $pokInlineExecCall: pokInlineExecCall
  else:
    raise newException(ValueError,
      "unknown privileged-operation kind tag: '" & s & "'")

proc isKnownPrivilegedOperationKind*(s: string): bool =
  ## Non-raising form, used by the closed-set validator to decide
  ## whether a wire frame names a recognized typed operation.
  try:
    discard privilegedOperationKindFromString(s)
    true
  except ValueError:
    false

# ---------------------------------------------------------------------------
# Sandbox-escape guard, shared by the fixture drivers AND the
# closed-set validator. A parent that supplies a `..`-bearing or
# absolute relative path is attempting to escape the sandbox; the
# broker rejects the operation outright.
# ---------------------------------------------------------------------------

proc isSafeRelativeSubPath*(p: string): bool =
  ## True only for a non-empty relative path with no `..` segment,
  ## no drive letter, and no leading separator. The broker uses this
  ## as a hard precondition before dispatching `pokFixtureFile` /
  ## `pokFixtureRegistry`.
  if p.len == 0:
    return false
  if p.len >= 2 and p[1] == ':':
    return false                       # drive-letter absolute path
  if p[0] == '/' or p[0] == '\\':
    return false                       # leading separator
  for seg in p.multiReplace(("\\", "/")).split('/'):
    if seg == ".." or seg == ".":
      return false
  return true

# ---------------------------------------------------------------------------
# macos.systemDefault — `defaults write` type-flag allowlist.
#
# `applyMacosSystemDefault` interpolates `sdValueType` straight into the
# `defaults write` command line (it does not branch on the flag). The
# value comes verbatim from a `system.nim` `type = "..."` field. To keep
# the broker's closed-typed-operation guarantee — "no parent-supplied
# value can break out of its shell argument" — the value MUST be one of
# the fixed `defaults write` type flags. A profile carrying
# `type = "-bool true; rm -rf /"` is rejected here before the operation
# ever reaches the elevated driver (defence-in-depth layer 1; the driver
# `quoteShell`s the flag as layer 2).
# ---------------------------------------------------------------------------

const MacosDefaultsTypeFlags* = [
  "-string", "-data", "-int", "-integer", "-float", "-bool", "-boolean",
  "-date", "-array", "-array-add", "-dict", "-dict-add"]
  ## The closed allowlist of `defaults write` type flags. `-int` /
  ## `-integer` and `-bool` / `-boolean` are both accepted forms the
  ## `defaults(1)` CLI recognizes. An empty `sdValueType` is also valid
  ## — the driver substitutes `-string` as its default.

proc isSafeDefaultsTypeFlag*(flag: string): bool =
  ## True when `flag` is an accepted `defaults write` type flag, or the
  ## empty string (the driver's `-string` default). Anything else —
  ## including any value bearing shell metacharacters or whitespace —
  ## is rejected so it can never reach the elevated `defaults write`.
  flag.len == 0 or flag in MacosDefaultsTypeFlags

# ---------------------------------------------------------------------------
# launchd.systemDaemon — launchd label charset allowlist.
#
# `observeLaunchdSystemDaemon` / `applyLaunchdSystemDaemon` interpolate
# `sdaLabel` into `launchctl print|bootout system/<label>` command
# lines. `isSafeDaemonLabel` (in posix_system_parse) blocks only path
# separators — it permits `;`, spaces, `$`, backticks, `&`, `|`,
# newlines. A launchd label is a reverse-DNS-style identifier; only
# alphanumerics, `.`, `-`, `_` have a legitimate place in one. This
# allowlist closes the residual shell-injection surface (defence-in-
# depth layer 1; the driver `quoteShell`s `system/<label>` as layer 2).
# ---------------------------------------------------------------------------

proc isSafeLaunchdLabel*(label: string): bool =
  ## True only for a non-empty launchd label whose every character is
  ## in the conservative reverse-DNS identifier charset
  ## (alphanumerics, `.`, `-`, `_`), and which is not `.` or `..`.
  ## Shell metacharacters, whitespace and path separators are refused.
  let l = label.strip()
  if l.len == 0:
    return false
  if l == "." or l == "..":
    return false
  for ch in l:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_'}:
      return false
  return true

# ---------------------------------------------------------------------------
# windows.service — recovery-action token codec + sc.exe argv assembler.
#
# Windows-System-Resources Phase B extends the `windows.service`
# operation with four optional fields (`displayName`, `binPath`,
# `recoveryActions`, `recoveryResetSeconds`). The pure logic that
# converts the typed `WindowsServiceRecoveryActionKind` enum to its
# string token and assembles the `sc.exe failure / sc.exe config` argv
# lives here so the cross-platform unit tests can exercise the formatter
# without a Windows host. The driver in
# `windows_system_driver.applyWindowsService` consumes these helpers
# verbatim.
# ---------------------------------------------------------------------------

proc windowsServiceRecoveryActionToken*(
    a: WindowsServiceRecoveryActionKind): string =
  ## The lower-case wire token for a recovery action; also the form
  ## `sc.exe failure ... actions=<a>/<d>/...` consumes. `wsrakNone`
  ## renders as the literal `""` argument the SCM treats as "no
  ## action".
  $a

proc windowsServiceRecoveryActionFromToken*(
    raw: string): WindowsServiceRecoveryActionKind =
  ## Strict parse of a recovery-action token. Accepts the canonical
  ## lower-case forms only — mirrors the closed-set posture of every
  ## other typed-field validator. Raises `ValueError` on a mismatch.
  case raw
  of "none": wsrakNone
  of "restart": wsrakRestart
  of "runcommand": wsrakRunCommand
  of "reboot": wsrakReboot
  else:
    raise newException(ValueError,
      "unknown windows.service recovery action token '" & raw &
      "' (expected one of restart / runcommand / reboot / none)")

proc isKnownWindowsServiceRecoveryActionToken*(raw: string): bool =
  ## Non-raising form for the closed-set validator. Mirrors
  ## `isKnownPrivilegedOperationKind` / `isSafeDefaultsTypeFlag`.
  raw in ["none", "restart", "runcommand", "reboot"]

proc scExeFailureActionToken*(
    a: WindowsServiceRecoveryActionKind): string =
  ## The `sc.exe failure ... actions=` token for a recovery action.
  ## `wsrakNone` -> empty string (the SCM treats an empty slot as "no
  ## action"); every other variant -> its lower-case token.
  case a
  of wsrakNone: ""
  of wsrakRestart: "restart"
  of wsrakRunCommand: "run"          # sc.exe's spelling of the cmdlet
  of wsrakReboot: "reboot"

proc renderScExeFailureActionsArg*(
    actions: seq[WindowsServiceRecoverySpec]): string =
  ## Build the `actions=` argument value `sc.exe failure` consumes:
  ## `<a1>/<d1>/<a2>/<d2>/<a3>/<d3>`. Each `<a>` is the lower-case
  ## token from `scExeFailureActionToken`; each `<d>` is the slot's
  ## delay-in-milliseconds. An empty `actions` seq returns the empty
  ## string — callers should test `actions.len > 0` and skip the
  ## `sc.exe failure` invocation entirely in that case.
  for i, e in actions:
    if i > 0:
      result.add('/')
    result.add(scExeFailureActionToken(e.action))
    result.add('/')
    result.add($e.delayMs)

proc renderScExeFailureCommand*(serviceName: string;
                                 resetSeconds: int;
                                 actions: seq[WindowsServiceRecoverySpec]):
    seq[string] =
  ## Build the argv `sc.exe failure <serviceName> reset= <secs>
  ## actions= <a1>/<d1>/...` consumes. Returned as a `seq[string]` so
  ## the driver can hand it directly to the spawning helper without a
  ## shell pass. NOTE: `sc.exe` is finicky — the `=` MUST be at the END
  ## of the option name and the value MUST be a separate argv entry, so
  ## the assembly emits `reset=` / `<secs>` / `actions=` / `<value>`
  ## as four separate argv tokens (NOT `"reset= <secs>"` jammed in one).
  result = @["sc.exe", "failure", serviceName]
  if resetSeconds > 0:
    result.add("reset=")
    result.add($resetSeconds)
  if actions.len > 0:
    result.add("actions=")
    result.add(renderScExeFailureActionsArg(actions))

proc renderScExeConfigBinPathCommand*(serviceName: string;
                                       binPath: string): seq[string] =
  ## Build the `sc.exe config <serviceName> binPath= "<binPath>"` argv.
  ## Returned as separate tokens for the same finicky-sc.exe reason as
  ## `renderScExeFailureCommand`.
  @["sc.exe", "config", serviceName, "binPath=", binPath]

proc renderScExeConfigDisplayNameCommand*(serviceName: string;
                                           displayName: string): seq[string] =
  ## Build the `sc.exe config <serviceName> DisplayName= "<displayName>"`
  ## argv.
  @["sc.exe", "config", serviceName, "DisplayName=", displayName]

# ---------------------------------------------------------------------------
# windows.scheduledTask — schedule token codec + argv assemblers.
#
# Windows-System-Resources Phase C: the `pokWindowsScheduledTask`
# operation carries a `ScheduledTaskScheduleSpec`. The wire token is the
# same `<kind>:<payload>` shape the front-end `repro_profile.types`
# codec uses — sharing the vocabulary means the adapter does NOT have
# to translate. The pure helpers below assemble:
#
#   * `Register-ScheduledTask` argv (creation path);
#   * `Set-ScheduledTask` argv (update path);
#   * `Unregister-ScheduledTask` argv (destroy path).
#
# Each is a `seq[string]` so the driver hands it directly to PowerShell
# without a shell pass. The driver in `windows_system_driver.applyWindows
# ScheduledTask` consumes these helpers verbatim.
# ---------------------------------------------------------------------------

proc scheduledTaskScheduleKindToken*(k: ScheduledTaskScheduleKind): string =
  ## Lower-case wire token for a schedule kind. Centralised so the
  ## codec, the validator and the canonical-text renderer all agree.
  $k

proc scheduledTaskScheduleKindFromToken*(
    raw: string): ScheduledTaskScheduleKind =
  ## Strict parse of a schedule-kind token. Raises `ValueError` on a
  ## mismatch — mirrors the closed-set posture of every other typed
  ## broker-side codec.
  case raw
  of "onBoot": wstskOnBoot
  of "onLogon": wstskOnLogon
  of "once": wstskOnce
  of "daily": wstskDaily
  of "interval": wstskInterval
  else:
    raise newException(ValueError,
      "unknown windows.scheduledTask schedule kind token '" & raw &
      "' (expected one of onBoot / onLogon / once / daily / interval)")

proc isKnownScheduledTaskScheduleKindToken*(raw: string): bool =
  ## Non-raising form for the closed-set validator.
  raw in ["onBoot", "onLogon", "once", "daily", "interval"]

proc isValidScheduledTaskTimeOfDay*(raw: string): bool =
  ## True only for a 24-hour `HH:MM` string. Mirrors the front-end
  ## `repro_profile.types.isValidScheduleTimeOfDay`; both surfaces need
  ## the same closed-set check (defence-in-depth).
  if raw.len != 5: return false
  if raw[2] != ':': return false
  for i in [0, 1, 3, 4]:
    if raw[i] notin {'0'..'9'}:
      return false
  let h = parseInt(raw[0 ..< 2])
  let m = parseInt(raw[3 ..< 5])
  h in 0..23 and m in 0..59

proc isValidScheduledTaskIso8601*(raw: string): bool =
  ## True for a non-empty string in the conservative ISO-8601 charset
  ## Task Scheduler accepts (digits + `-`, `:`, `T`, `Z`, `+`, `.`).
  if raw.len == 0: return false
  for ch in raw:
    if ch notin {'0'..'9', '-', ':', 'T', 'Z', '+', '.'}:
      return false
  true

proc encodeScheduledTaskScheduleSpec*(
    s: ScheduledTaskScheduleSpec): string =
  ## Encode a `ScheduledTaskScheduleSpec` to its canonical wire token.
  ## REJECTS malformed shapes (negative delay, non-positive interval,
  ## empty / malformed required-time fields) so a bypass through the
  ## adapter still fails closed.
  case s.kind
  of wstskOnBoot:
    if s.delaySeconds < 0:
      raise newException(ValueError,
        "windows.scheduledTask onBoot delaySeconds '" &
        $s.delaySeconds & "' is negative (must be >= 0)")
    "onBoot:" & $s.delaySeconds
  of wstskOnLogon:
    "onLogon:" & s.forUser
  of wstskOnce:
    if not isValidScheduledTaskIso8601(s.runAt):
      raise newException(ValueError,
        "windows.scheduledTask once runAt '" & s.runAt &
        "' is not a valid ISO-8601 timestamp")
    "once:" & s.runAt
  of wstskDaily:
    if not isValidScheduledTaskTimeOfDay(s.timeOfDay):
      raise newException(ValueError,
        "windows.scheduledTask daily timeOfDay '" & s.timeOfDay &
        "' is not a valid HH:MM 24-hour time")
    "daily:" & s.timeOfDay
  of wstskInterval:
    if s.everyMinutes <= 0:
      raise newException(ValueError,
        "windows.scheduledTask interval everyMinutes '" &
        $s.everyMinutes & "' must be > 0")
    if s.startAt.len > 0 and not isValidScheduledTaskIso8601(s.startAt):
      raise newException(ValueError,
        "windows.scheduledTask interval startAt '" & s.startAt &
        "' is not a valid ISO-8601 timestamp")
    "interval:" & $s.everyMinutes & ":" & s.startAt

proc decodeScheduledTaskScheduleToken*(
    token: string): ScheduledTaskScheduleSpec =
  ## Decode a canonical wire token into a `ScheduledTaskScheduleSpec`.
  ## Rejects every malformed shape (unknown tag, missing required
  ## field, non-integer numeric half, negative delay, non-positive
  ## interval).
  let sep = token.find(':')
  if sep <= 0:
    raise newException(ValueError,
      "windows.scheduledTask schedule token '" & token &
      "' is malformed (expected '<kind>:<payload>')")
  let kindTok = token[0 ..< sep]
  let payload = token[sep + 1 .. ^1]
  if not isKnownScheduledTaskScheduleKindToken(kindTok):
    raise newException(ValueError,
      "windows.scheduledTask schedule token '" & token &
      "' names an unknown kind '" & kindTok &
      "' (expected one of onBoot / onLogon / once / daily / interval)")
  let kind = scheduledTaskScheduleKindFromToken(kindTok)
  case kind
  of wstskOnBoot:
    var delaySeconds: int
    try:
      delaySeconds = parseInt(payload)
    except ValueError:
      raise newException(ValueError,
        "windows.scheduledTask onBoot delaySeconds '" & payload &
        "' is not an integer")
    if delaySeconds < 0:
      raise newException(ValueError,
        "windows.scheduledTask onBoot delaySeconds '" & payload &
        "' is negative (must be >= 0)")
    ScheduledTaskScheduleSpec(kind: wstskOnBoot,
      delaySeconds: delaySeconds)
  of wstskOnLogon:
    ScheduledTaskScheduleSpec(kind: wstskOnLogon, forUser: payload)
  of wstskOnce:
    if not isValidScheduledTaskIso8601(payload):
      raise newException(ValueError,
        "windows.scheduledTask once runAt '" & payload &
        "' is not a valid ISO-8601 timestamp")
    ScheduledTaskScheduleSpec(kind: wstskOnce, runAt: payload)
  of wstskDaily:
    if not isValidScheduledTaskTimeOfDay(payload):
      raise newException(ValueError,
        "windows.scheduledTask daily timeOfDay '" & payload &
        "' is not a valid HH:MM 24-hour time")
    ScheduledTaskScheduleSpec(kind: wstskDaily, timeOfDay: payload)
  of wstskInterval:
    let sep2 = payload.find(':')
    if sep2 < 0:
      raise newException(ValueError,
        "windows.scheduledTask interval payload '" & payload &
        "' is malformed (expected '<everyMinutes>:<startAt>')")
    let everyStr = payload[0 ..< sep2]
    let startAt = payload[sep2 + 1 .. ^1]
    var everyMinutes: int
    try:
      everyMinutes = parseInt(everyStr)
    except ValueError:
      raise newException(ValueError,
        "windows.scheduledTask interval everyMinutes '" & everyStr &
        "' is not an integer")
    if everyMinutes <= 0:
      raise newException(ValueError,
        "windows.scheduledTask interval everyMinutes '" & everyStr &
        "' must be > 0")
    if startAt.len > 0 and not isValidScheduledTaskIso8601(startAt):
      raise newException(ValueError,
        "windows.scheduledTask interval startAt '" & startAt &
        "' is not a valid ISO-8601 timestamp")
    ScheduledTaskScheduleSpec(kind: wstskInterval,
      everyMinutes: everyMinutes, startAt: startAt)

proc `==`*(a, b: ScheduledTaskScheduleSpec): bool =
  ## Structural equality for `ScheduledTaskScheduleSpec`. Used by the
  ## drift comparator + the codec round-trip tests.
  if a.kind != b.kind:
    return false
  case a.kind
  of wstskOnBoot: a.delaySeconds == b.delaySeconds
  of wstskOnLogon: a.forUser == b.forUser
  of wstskOnce: a.runAt == b.runAt
  of wstskDaily: a.timeOfDay == b.timeOfDay
  of wstskInterval:
    a.everyMinutes == b.everyMinutes and a.startAt == b.startAt

const
  ScheduledTaskAllowedPrincipals* = ["SYSTEM", "LOCAL_SERVICE",
                                     "NETWORK_SERVICE"]
    ## The three special-principal forms the driver maps to the
    ## corresponding `New-ScheduledTaskPrincipal -UserId` value. A
    ## non-special principal (`DOMAIN\user` or a SID) is accepted by
    ## the validator via the `isSafeScheduledTaskPrincipal` charset
    ## check.

proc isSafeScheduledTaskTaskName*(name: string): bool =
  ## True only for a non-empty fully-qualified Task Scheduler path that
  ## stays in the conservative charset (letters, digits, `\`, `/`, `.`,
  ## `-`, `_`, ` `). A `..` segment is refused as a sandbox-escape
  ## guard; the leading `\` is allowed (Task Scheduler's root prefix);
  ## quote / shell metacharacter / control character are refused so the
  ## name cannot smuggle a PowerShell pipeline past `psQuote` at the
  ## driver edge.
  let n = name.strip()
  if n.len == 0:
    return false
  for ch in n:
    if ord(ch) < 0x20 or ord(ch) == 0x7f:
      return false
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9',
                 '\\', '/', '.', '-', '_', ' '}:
      return false
  for seg in n.multiReplace(("\\", "/")).split('/'):
    if seg == "..":
      return false
  true

proc isSafeScheduledTaskExecutable*(path: string): bool =
  ## True for a non-empty path with no NUL byte / quote / control
  ## character. The driver `psQuote`s this as defence-in-depth layer 2;
  ## the closed-set check here is layer 1.
  if path.len == 0: return false
  for ch in path:
    if ord(ch) < 0x20 or ord(ch) == 0x7f:
      return false
    if ch in {'"', '\n', '\r', '\x00'}:
      return false
  true

proc isSafeScheduledTaskPrincipal*(p: string): bool =
  ## True for one of the special principals OR a `DOMAIN\user` /
  ## SID-form string in the conservative charset (letters, digits,
  ## `\`, `.`, `-`, `_`, `@`).
  if p in ScheduledTaskAllowedPrincipals:
    return true
  let s = p.strip()
  if s.len == 0: return false
  for ch in s:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9',
                 '\\', '.', '-', '_', '@'}:
      return false
  true

proc renderScheduledTaskScheduleXml*(
    s: ScheduledTaskScheduleSpec): string =
  ## Build the Task Scheduler `<Triggers>` XML fragment for a single
  ## trigger. Pure — the driver substitutes this into the full task
  ## XML before handing it to `Register-ScheduledTask`. Each branch
  ## emits the canonical Task Scheduler element shape; missing optional
  ## fields collapse to the empty form Task Scheduler treats as "use
  ## defaults".
  case s.kind
  of wstskOnBoot:
    var xml = "<BootTrigger>"
    if s.delaySeconds > 0:
      xml.add("<Delay>PT" & $s.delaySeconds & "S</Delay>")
    xml.add("</BootTrigger>")
    xml
  of wstskOnLogon:
    var xml = "<LogonTrigger>"
    if s.forUser.len > 0:
      xml.add("<UserId>" & s.forUser & "</UserId>")
    xml.add("</LogonTrigger>")
    xml
  of wstskOnce:
    "<TimeTrigger><StartBoundary>" & s.runAt &
      "</StartBoundary></TimeTrigger>"
  of wstskDaily:
    # Task Scheduler daily triggers require a full ISO-8601
    # StartBoundary; the driver substitutes `1970-01-01T<HH:MM>:00` so
    # the trigger fires at `HH:MM` every day from epoch. The non-XML
    # canonical text keeps the operator-facing `HH:MM` shape; the
    # driver compares observation against this canonical form.
    "<CalendarTrigger><StartBoundary>1970-01-01T" & s.timeOfDay &
      ":00</StartBoundary><ScheduleByDay><DaysInterval>1</DaysInterval>" &
      "</ScheduleByDay></CalendarTrigger>"
  of wstskInterval:
    var xml = "<TimeTrigger>"
    if s.startAt.len > 0:
      xml.add("<StartBoundary>" & s.startAt & "</StartBoundary>")
    xml.add("<Repetition><Interval>PT" & $s.everyMinutes &
      "M</Interval></Repetition></TimeTrigger>")
    xml

proc renderRegisterScheduledTaskCommand*(taskName, executable: string;
                                         arguments: seq[string];
                                         workingDirectory: string;
                                         runAsUser: string;
                                         runWithHighestPrivileges: bool;
                                         scheduleXml: string;
                                         enabled: bool): seq[string] =
  ## Assemble the argv for the `Register-ScheduledTask` PowerShell
  ## invocation as a sequence of tokens. The driver hands this to
  ## PowerShell verbatim. The token list is the canonical argv shape
  ## the pure assembler builds; the driver's `psQuote` pass at fork
  ## time covers the actual shell-level quoting.
  result = @["Register-ScheduledTask",
             "-TaskName", taskName,
             "-Action", "New-ScheduledTaskAction -Execute " & executable]
  if arguments.len > 0:
    result.add("-ArgumentList")
    var args = ""
    for i, a in arguments:
      if i > 0:
        args.add(' ')
      args.add(a)
    result.add(args)
  if workingDirectory.len > 0:
    result.add("-WorkingDirectory")
    result.add(workingDirectory)
  result.add("-Trigger")
  result.add(scheduleXml)
  let principalToken =
    if runAsUser in ScheduledTaskAllowedPrincipals: runAsUser
    else: runAsUser
  result.add("-Principal")
  result.add(principalToken)
  if runWithHighestPrivileges:
    result.add("-RunLevel")
    result.add("Highest")
  if not enabled:
    result.add("-Settings")
    result.add("Disabled")

proc renderUnregisterScheduledTaskCommand*(taskName: string): seq[string] =
  ## Assemble the argv for the `Unregister-ScheduledTask` destroy path.
  ## `-Confirm:$false` so the cmdlet does not prompt.
  @["Unregister-ScheduledTask",
    "-TaskName", taskName,
    "-Confirm:$false"]

# ---------------------------------------------------------------------------
# windows.firewallRule — protocol/direction/action allowlists and
# identifier/port charset guards.
#
# The `New-/Set-/Get-/Remove-NetFirewallRule` cmdlets are wrapped from
# strings composed of typed fields; defence-in-depth layer 1 is to
# allow only closed enumeration values for the protocol/direction/
# action fields and a conservative charset for `fwName`/`fwLocalPort`
# so a `protocol = "TCP'; <cmd>"` profile cannot reach arbitrary root
# execution. Layer 2 is `psQuote` in the driver.
# ---------------------------------------------------------------------------

const
  FirewallProtocols* = ["TCP", "UDP", "ICMPv4", "ICMPv6", "Any"]
  FirewallDirections* = ["Inbound", "Outbound"]
  FirewallActions* = ["Allow", "Block"]

proc isSafeFirewallIdentifier*(name: string): bool =
  ## Rule names flow into `-Name <value>` PowerShell arguments. The
  ## `New-NetFirewallRule` documentation allows arbitrary unicode in
  ## `-Name`, but Reprobuild restricts the charset to alphanumerics,
  ## `.`, `-`, `_` and a single space so the value cannot break out of
  ## a `psQuote`d argument and so two profiles can compare names
  ## byte-for-byte. Anything else is refused at validation time.
  let n = name.strip()
  if n.len == 0:
    return false
  for ch in n:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_', ' '}:
      return false
  return true

proc isSafeFirewallDisplayName*(displayName: string): bool =
  ## Display names may contain spaces and parentheses (the OpenSSH
  ## rule's canonical label is `OpenSSH Server (sshd)`) but never a
  ## single-quote or a control character — both would break the
  ## `psQuote`'d argument that wraps the value.
  if displayName.len == 0:
    return true
  for ch in displayName:
    if ch == '\'' or ord(ch) < 0x20 or ord(ch) == 0x7f:
      return false
  return true

proc isSafeFirewallPort*(port: string): bool =
  ## A localPort field accepts a single port (`22`), a comma-separated
  ## list (`22,2222`), a port range (`8000-9000`), the literal `Any`,
  ## or the empty string (the driver substitutes `Any`). Everything
  ## else is refused so the field cannot smuggle a shell metacharacter
  ## past the closed-set validator.
  let p = port.strip()
  if p.len == 0:
    return true
  if p == "Any" or p == "any":
    return true
  for ch in p:
    if ch notin {'0'..'9', ',', '-', ' '}:
      return false
  return true

# ---------------------------------------------------------------------------
# windows.acl — path / principal / ACE / inheritance-mode allowlists.
#
# The `icacls` and `takeown` CLIs are wrapped from strings composed of
# typed fields; defence-in-depth layer 1 is a closed allowlist on the
# inheritance mode + a conservative charset on the path / principal /
# ACE-spec values so a `principal = "BUILTIN\Administrators; <cmd>"`
# profile cannot reach arbitrary root execution. Layer 2 is
# `quoteShell` in the driver (icacls is a plain Win32 console tool —
# it uses cmd-shell argv rules, NOT PowerShell — so quoting is
# `quoteShell`, not `psQuote`).
# ---------------------------------------------------------------------------

const
  AclInheritanceModes* = ["enabled", "disabled-replace", "disabled-convert"]
  DirectoryAclInheritanceModes* = ["enabled", "disabled-replace",
                                   "disabled-convert",
                                   "protected-clear-inherited"]
    ## The inheritance-mode vocabulary `fs.systemDirectory`'s inline
    ## ACL builder accepts — `AclInheritanceModes` plus
    ## `protected-clear-inherited`. The new value disables inheritance
    ## AND clears every previously-inherited ACE so only the explicit
    ## ACEs declared in the stanza remain, which is the
    ## actions-runner-tokens directory's production requirement
    ## (`disabled-replace` only flushes inherited ACEs at the moment
    ## inheritance is disabled — a subsequent re-inherit pass can
    ## reintroduce them; `protected-clear-inherited` is the
    ## SetAccessRuleProtection(true, false) shape that pins the DACL).

proc isSafeAclPath*(path: string): bool =
  ## True only for a non-empty absolute Windows path with no `..`
  ## segment and no shell metacharacter / control character / quote.
  ## The path flows into `icacls <path>` and `takeown /F <path>`
  ## argument positions; both are plain console tools that parse argv
  ## via cmd-shell rules. `quoteShell` (layer 2) handles spaces, but
  ## a `"` / `\n` / `;` / `&` / `|` / `<` / `>` / `^` / `` ` `` can
  ## still subvert the argv parse, and a `..` segment can escape the
  ## intended scope — both are refused here.
  let p = path.strip()
  if p.len == 0:
    return false
  # Reject characters cmd.exe interprets specially or that don't have
  # a legitimate place in an NTFS path. NTFS forbids `<>:"/\\|?*`
  # inside a path component (the path itself uses `\` as separator and
  # may contain a single `:` after the drive letter); we apply the
  # restrictive subset here.
  for ch in p:
    if ord(ch) < 0x20 or ord(ch) == 0x7f:
      return false
    if ch in {'"', '*', '?', '<', '>', '|', '\'', '`', '$', ';', '&',
              '^', '!', '%', '\n', '\r'}:
      return false
  # Disallow `..` as a path segment (escape).
  for seg in p.multiReplace(("\\", "/")).split('/'):
    if seg == "..":
      return false
  return true

proc isSafeAclPrincipal*(principal: string): bool =
  ## True only for a non-empty NTAccount-form name or SID. NTAccount
  ## forms have shape `<authority>\<name>` (e.g. `BUILTIN\Administrators`
  ## or `NT AUTHORITY\SYSTEM`) or a bare local name (`Administrators`).
  ## SIDs have shape `S-1-...`. Allowed charset: alphanumerics, `\`,
  ## ` `, `.`, `-`, `_`, `@`. Single-quote / double-quote / control /
  ## shell metacharacter / `:` are refused so the principal cannot
  ## smuggle ACE-spec syntax or shell metacharacters past the
  ## closed-set validator.
  let p = principal.strip()
  if p.len == 0:
    return false
  for ch in p:
    if ord(ch) < 0x20 or ord(ch) == 0x7f:
      return false
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9',
                 '\\', ' ', '.', '-', '_', '@'}:
      return false
  return true

proc isSafeAclEntry*(entry: string): bool =
  ## True only for a non-empty ACE spec `<principal>:<spec>` whose
  ## principal half is `isSafeAclPrincipal` and whose spec half is in
  ## the closed icacls charset:
  ##   * uppercase ASCII letters (icacls permission codes: F, M, RX,
  ##     R, W, D, GA, GW, GR, WO, WDAC, ...)
  ##   * `,` (permission-list separator inside parentheses)
  ##   * `(` / `)` (inheritance + permission groups)
  ##   * digits (rare — e.g. `(IO)` indices)
  ## A `:` is allowed exactly once and is the separator between the
  ## two halves; a stray semicolon, backtick, dollar sign, etc. is
  ## refused. The colon position is determined by the FIRST `:` so a
  ## SID-form principal (no colon in `S-1-...`) parses correctly.
  let e = entry.strip()
  if e.len == 0:
    return false
  let colon = e.find(':')
  if colon <= 0 or colon == e.len - 1:
    return false
  let principal = e[0 ..< colon]
  let spec = e[colon + 1 .. ^1]
  if not isSafeAclPrincipal(principal):
    return false
  for ch in spec:
    if ord(ch) < 0x20 or ord(ch) == 0x7f:
      return false
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '(', ')', ',', ' '}:
      return false
  return true

# ---------------------------------------------------------------------------
# Linux drop-in driver shared validators (M83 step 5).
#
# The Linux drop-in driver family (sysctl / udevRule / polkitRule /
# sudoersRule / tmpfilesRule — landed across step 5 commits) all write
# ONE basename into ONE fixed `/etc/X.d/` directory. The basename flows
# into a `quoteShell`'d argument and into a shell-out, so layer-1
# defence is a conservative basename charset + a hard requirement that
# it be a single path segment (no `/`, no `\`, no `..`). The sysctl key
# is a dotted kernel-parameter identifier (e.g.
# `kernel.perf_event_paranoid`) — its charset is well-known and a closed
# allowlist closes the residual command-injection surface. The CONTENT
# of each drop-in file is a verbatim file write; it never reaches the
# shell, so a newline in the body is fine.
# ---------------------------------------------------------------------------

proc isSafeDropInBasename*(name: string): bool =
  ## True only for a non-empty single-segment basename: no path
  ## separator, no `..`, no shell metacharacter, charset restricted to
  ## alphanumerics, `.`, `-`, `_`. The Linux drop-in driver family uses
  ## this as a hard precondition before dispatching any I/O so a
  ## profile carrying `name = "../etc/shadow"` cannot escape the fixed
  ## `/etc/X.d/` directory and so a `name = "x; rm -rf /"` cannot
  ## smuggle a shell metacharacter past the closed-set validator.
  let n = name.strip()
  if n.len == 0:
    return false
  if n == "." or n == "..":
    return false
  for ch in n:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_'}:
      return false
  return true

proc isSafeSysctlKey*(key: string): bool =
  ## True only for a non-empty sysctl key in the conservative kernel-
  ## parameter charset: alphanumerics, `.`, `-`, `_`, `/`. (The `/`
  ## form is the `/proc/sys/...` path equivalent that `sysctl` also
  ## accepts; both forms appear in real-world `sysctl.d` files.) The
  ## key flows into `sysctl -n <key>` AND into a `<key> = <value>` file
  ## line; both surfaces need a closed charset so neither path can
  ## smuggle a shell metacharacter or a stray `=` past validation.
  let k = key.strip()
  if k.len == 0:
    return false
  for ch in k:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_', '/'}:
      return false
  return true

proc isSafeSysctlValue*(value: string): bool =
  ## True only for a sysctl value that does not contain a newline. The
  ## value is interpolated into a `<key> = <value>\n` file line; a
  ## newline in the value would corrupt the file by injecting a
  ## spurious key=value entry. Other shell metacharacters are fine —
  ## the value never reaches the shell, only the file.
  for ch in value:
    if ch == '\n' or ch == '\r':
      return false
  return true

# ---------------------------------------------------------------------------
# passwd.group — group name + gid + member charset guards.
#
# `pgName` flows into `groupadd` / `groupmod` / `groupdel` / `gpasswd`
# argv via `quoteShell`; `pgGid` is interpolated into `--gid <gid>`.
# Defence-in-depth layer 1 is a closed charset for the name (the POSIX
# group-name convention is the conservative `useradd(8)` set —
# alphanumerics, `.`, `-`, `_`, with no leading `-`) and digits-only
# for the gid. The member list is validated identically to the
# `pgName` so a username smuggled into `usermod -aG <name> <user>`
# cannot break out of its argument.
# ---------------------------------------------------------------------------

proc isSafePosixUserOrGroupName*(name: string): bool =
  ## True only for a non-empty POSIX-style user or group name in the
  ## conservative `useradd(8)` charset: alphanumerics, `.`, `-`, `_`,
  ## with no leading `-` (an argument that starts with `-` is parsed
  ## by `groupadd` / `usermod` / `gpasswd` as an option, not a name).
  ## Refuses `.` and `..` explicitly as defence-in-depth. The trailing
  ## `$` that Samba accounts use is permitted only at the end of the
  ## name (a `$` mid-string is refused).
  let n = name.strip()
  if n.len == 0:
    return false
  if n == "." or n == "..":
    return false
  if n[0] == '-':
    return false
  for i in 0 ..< n.len:
    let ch = n[i]
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_'}:
      continue
    if ch == '$' and i == n.len - 1:
      continue
    return false
  return true

proc isSafeGid*(gid: string): bool =
  ## True only for the empty string (unpinned) or a non-empty digits-
  ## only decimal gid in the 0..4294967295 range. The decimal-only
  ## charset closes the residual command-injection surface (gid flows
  ## into `--gid <gid>` as a separate argv element, but the closed
  ## charset is defence-in-depth on top of `quoteShell`).
  if gid.len == 0:
    return true
  for ch in gid:
    if ch notin {'0'..'9'}:
      return false
  return true

proc isSafeNixDaemonKey*(key: string): bool =
  ## True only for a non-empty Nix-daemon config key in the
  ## conservative charset: alphanumerics, `-`, `_`. Real Nix keys
  ## (`experimental-features`, `substituters`, `trusted-users`,
  ## `auto-optimise-store`) all fall in this set; `.` / `/` / shell
  ## metacharacters never appear in a legitimate Nix key. The key is
  ## interpolated into a `<key> = <value>` file line and into the
  ## `key:` prefix grep that observes the live file, so a closed
  ## charset is necessary for both surfaces.
  let k = key.strip()
  if k.len == 0:
    return false
  for ch in k:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '-', '_'}:
      return false
  return true

proc isSafeNixDaemonValue*(value: string): bool =
  ## True only for a Nix-daemon value that does not contain a newline.
  ## The value is interpolated into a `<key> = <value>\n` file line; a
  ## newline in the value would corrupt the file. Other characters
  ## (including `=` and shell metacharacters) are fine — the value
  ## never reaches a shell, only the file.
  for ch in value:
    if ch == '\n' or ch == '\r':
      return false
  return true

# ---------------------------------------------------------------------------
# linux.firewallRule — nftables protocol / action / direction allowlists
# and chain / identifier / port charset guards.
#
# The four chain/protocol/action/direction fields flow into `nft add
# rule <chain> <protocol> dport <port> <action> comment "repro-fw-<name>"`
# command lines; defence-in-depth layer 1 is to allow only closed
# enumeration values for the protocol / direction / action fields and
# a conservative charset for `lfwChain` / `lfwName` / `lfwLocalPort`
# so a `action = "accept; <cmd>"` profile cannot reach arbitrary root
# execution. Layer 2 is `quoteShell` on the assembled argv.
# ---------------------------------------------------------------------------

const
  LinuxFirewallProtocols* = ["tcp", "udp", "icmp", "icmpv6"]
  LinuxFirewallDirections* = ["inbound", "outbound"]
  LinuxFirewallActions* = ["accept", "drop", "reject"]

proc isSafeNftChain*(chain: string): bool =
  ## True only for a non-empty nftables chain triple in the form
  ## `<family> <table> <chain>` (e.g. `inet filter input`). Each
  ## component is restricted to the conservative nftables identifier
  ## charset (letters, digits, `-`, `_`); exactly two single-space
  ## separators between the three components. This refuses anything
  ## that could smuggle a shell metacharacter or break the `nft add
  ## rule` argv shape.
  let c = chain.strip()
  if c.len == 0:
    return false
  let parts = c.split(' ')
  if parts.len != 3:
    return false
  for p in parts:
    if p.len == 0:
      return false
    for ch in p:
      if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '-', '_'}:
        return false
  return true

proc isSafeNftRuleName*(name: string): bool =
  ## True only for a non-empty rule identifier in the conservative
  ## charset (letters, digits, `.`, `-`, `_`). The name is embedded
  ## verbatim into the rule's comment (`comment "repro-fw-<name>"`)
  ## and used as a `grep "repro-fw-<name>"` match; closing the
  ## charset means neither surface can be confused by a smuggled
  ## quote, comment separator, or shell metacharacter.
  let n = name.strip()
  if n.len == 0:
    return false
  if n == "." or n == "..":
    return false
  for ch in n:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_'}:
      return false
  return true

proc isSafeNftPort*(port: string): bool =
  ## True for a single port (`22`), a comma-separated list
  ## (`22,2222`), a port range (`8000-9000`), the literal `any`, or
  ## the empty string. Everything else is refused so the field
  ## cannot smuggle a shell metacharacter past the closed-set
  ## validator. (Mirrors `isSafeFirewallPort` for the Windows side.)
  let p = port.strip()
  if p.len == 0:
    return true
  if p == "any":
    return true
  for ch in p:
    if ch notin {'0'..'9', ',', '-', ' '}:
      return false
  return true

# ---------------------------------------------------------------------------
# Closed-set validation. The broker calls `validateOperation` on
# every decoded `PrivilegedOperation` before dispatch — a frame that
# is structurally a `PrivilegedOperation` but carries an out-of-policy
# payload (sandbox escape) is rejected with `EProtocol`, never run.
# ---------------------------------------------------------------------------

proc operationValidationError*(op: PrivilegedOperation): string =
  ## Returns "" when the operation is in-policy, otherwise a human
  ## diagnostic. Pure — callers turn a non-empty result into
  ## `EProtocol`.
  if op.address.len == 0:
    return "privileged operation has an empty address"
  case op.kind
  of pokFixtureFile:
    if not isSafeRelativeSubPath(op.fileRelPath):
      return "fixture.systemFile path '" & op.fileRelPath &
        "' is not a safe relative path (sandbox escape refused)"
  of pokFixtureRegistry:
    if not isSafeRelativeSubPath(op.regSubPath):
      return "fixture.systemRegistry sub-path '" & op.regSubPath &
        "' is not a safe relative path (sandbox escape refused)"
    if op.regValueName.len == 0:
      return "fixture.systemRegistry operation has an empty value name"
  of pokWindowsRegistryValue:
    if not isSafeRelativeSubPath(op.hklmSubkey):
      return "windows.registryValue HKLM subkey '" & op.hklmSubkey &
        "' is not a safe relative subkey path"
    # An empty value name targets the key's default value — allowed.
  of pokWindowsOptionalFeature:
    if op.featureName.len == 0:
      return "windows.optionalFeature operation has an empty feature name"
  of pokWindowsCapability:
    if op.capabilityName.len == 0:
      return "windows.capability operation has an empty capability name"
  of pokWindowsService:
    if op.serviceName.len == 0:
      return "windows.service operation has an empty service name"
    if op.serviceStartType notin ["Automatic", "Manual", "Disabled"]:
      return "windows.service start-type '" & op.serviceStartType &
        "' is not one of Automatic / Manual / Disabled"
    # Windows-System-Resources Phase B: validate the four new fields.
    # The action enum's closed-set check rides the typed variant itself
    # (a frame decoder catches a bad token before this proc sees it), so
    # we only sanity-check the delay/reset numerics + cap the slot count
    # at 3 (sc.exe failure consumes at most three positional slots).
    if op.serviceRecoveryResetSeconds < 0:
      return "windows.service recoveryResetSeconds for '" &
        op.serviceName & "' is negative (must be >= 0)"
    if op.serviceRecoveryActions.len > 3:
      return "windows.service recoveryActions for '" & op.serviceName &
        "' has " & $op.serviceRecoveryActions.len &
        " entries — sc.exe failure consumes at most 3 slots"
    for idx, slot in op.serviceRecoveryActions:
      if slot.delayMs < 0:
        return "windows.service recoveryActions[" & $idx & "] for '" &
          op.serviceName & "' has a negative delayMs (must be >= 0)"
  of pokWindowsScheduledTask:
    # Windows-System-Resources Phase C: the broker validator is the
    # final closed-set guard before the typed driver dispatches. Every
    # field the operation carries is sanity-checked; a frame that
    # arrived through the wire codec already had its schedule token
    # decoded (codec rejects unknown kind), but the broker re-checks
    # the empty-name / executable / principal cases here as
    # defence-in-depth.
    if op.wstTaskName.strip().len == 0:
      return "windows.scheduledTask operation has an empty taskName"
    if not isSafeScheduledTaskTaskName(op.wstTaskName):
      return "windows.scheduledTask taskName '" & op.wstTaskName &
        "' contains characters outside the safe Task Scheduler path " &
        "charset (letters, digits, '\\', '/', '.', '-', '_', ' '; no " &
        "'..' segment, no quote / shell metacharacter / control character)"
    if op.wstExecutable.strip().len == 0:
      return "windows.scheduledTask '" & op.wstTaskName &
        "' has an empty executable"
    if not isSafeScheduledTaskExecutable(op.wstExecutable):
      return "windows.scheduledTask '" & op.wstTaskName &
        "' executable '" & op.wstExecutable &
        "' contains a NUL byte / quote / control character"
    if op.wstRunAsUser.len > 0 and
       not isSafeScheduledTaskPrincipal(op.wstRunAsUser):
      return "windows.scheduledTask runAsUser '" & op.wstRunAsUser &
        "' is not one of " &
        ScheduledTaskAllowedPrincipals.join(" / ") &
        " and is not a safe `DOMAIN\\user` / SID-form principal " &
        "(allowed charset: letters, digits, '\\', '.', '-', '_', '@')"
    # Schedule kind-specific guards. Mirrors the codec's
    # `decodeScheduledTaskScheduleToken` checks but on the typed value
    # — a frame that bypassed the codec (in-process construction)
    # still fails closed here.
    case op.wstSchedule.kind
    of wstskOnBoot:
      if op.wstSchedule.delaySeconds < 0:
        return "windows.scheduledTask '" & op.wstTaskName &
          "' onBoot delaySeconds is negative (must be >= 0)"
    of wstskOnLogon:
      discard          # forUser may legitimately be empty (any-user)
    of wstskOnce:
      if not isValidScheduledTaskIso8601(op.wstSchedule.runAt):
        return "windows.scheduledTask '" & op.wstTaskName &
          "' once runAt '" & op.wstSchedule.runAt &
          "' is not a valid ISO-8601 timestamp"
    of wstskDaily:
      if not isValidScheduledTaskTimeOfDay(op.wstSchedule.timeOfDay):
        return "windows.scheduledTask '" & op.wstTaskName &
          "' daily timeOfDay '" & op.wstSchedule.timeOfDay &
          "' is not a valid HH:MM 24-hour time"
    of wstskInterval:
      if op.wstSchedule.everyMinutes <= 0:
        return "windows.scheduledTask '" & op.wstTaskName &
          "' interval everyMinutes '" &
          $op.wstSchedule.everyMinutes & "' must be > 0"
      if op.wstSchedule.startAt.len > 0 and
         not isValidScheduledTaskIso8601(op.wstSchedule.startAt):
        return "windows.scheduledTask '" & op.wstTaskName &
          "' interval startAt '" & op.wstSchedule.startAt &
          "' is not a valid ISO-8601 timestamp"
  of pokWindowsVsInstaller:
    if op.vsEdition.len == 0:
      return "windows.vsInstaller operation has an empty edition"
    if op.vsChannel.len == 0:
      return "windows.vsInstaller operation has an empty channel"
    # A modify / uninstall both need the install path; an install
    # without one defaults to the VS standard location, so an empty
    # install path is allowed only for a fresh install — the driver's
    # re-observe handles the distinction.
  of pokWindowsFirewallRule:
    if op.fwName.strip().len == 0:
      return "windows.firewallRule operation has an empty name"
    if not isSafeFirewallIdentifier(op.fwName):
      return "windows.firewallRule name '" & op.fwName &
        "' contains characters outside the firewall-identifier charset " &
        "(letters, digits, '.', '-', '_', space)"
    if op.fwDisplayName.len > 0 and not isSafeFirewallDisplayName(
        op.fwDisplayName):
      return "windows.firewallRule displayName '" & op.fwDisplayName &
        "' contains a single-quote or control character"
    if op.fwProtocol notin FirewallProtocols:
      return "windows.firewallRule protocol '" & op.fwProtocol &
        "' is not one of " & FirewallProtocols.join(" / ")
    if op.fwDirection notin FirewallDirections:
      return "windows.firewallRule direction '" & op.fwDirection &
        "' is not one of " & FirewallDirections.join(" / ")
    if op.fwAction notin FirewallActions:
      return "windows.firewallRule action '" & op.fwAction &
        "' is not one of " & FirewallActions.join(" / ")
    if op.fwLocalPort.len > 0 and not isSafeFirewallPort(op.fwLocalPort):
      return "windows.firewallRule localPort '" & op.fwLocalPort &
        "' is not a port number, port range, comma list, or 'Any'"
  of pokWindowsAcl:
    if op.aclPath.strip().len == 0:
      return "windows.acl operation has an empty path"
    if not isSafeAclPath(op.aclPath):
      return "windows.acl path '" & op.aclPath &
        "' contains characters outside the safe-path charset " &
        "(no '..' segment, no quote / shell metacharacter / " &
        "control character)"
    if op.aclOwner.len > 0 and not isSafeAclPrincipal(op.aclOwner):
      return "windows.acl owner '" & op.aclOwner &
        "' contains characters outside the principal charset " &
        "(letters, digits, '\\', ' ', '.', '-', '_', '@')"
    if op.aclInheritanceMode.len > 0 and
       op.aclInheritanceMode notin AclInheritanceModes:
      return "windows.acl inheritanceMode '" & op.aclInheritanceMode &
        "' is not one of " & AclInheritanceModes.join(" / ")
    if not op.aclDestroy and op.aclEntries.len == 0:
      return "windows.acl '" & op.aclPath &
        "' has an empty accessControlEntries list (a non-destroy " &
        "apply must declare at least one ACE)"
    for ace in op.aclEntries:
      if not isSafeAclEntry(ace):
        return "windows.acl entry '" & ace &
          "' is not a safe `<principal>:<perms>` ACE spec " &
          "(principal must be in the NTAccount / SID charset; perms " &
          "must use only icacls permission codes, '(', ')', ',', ' ')"
  of pokMacosSystemDefault:
    if op.sdDomain.len == 0:
      return "macos.systemDefault operation has an empty domain"
    if op.sdKey.len == 0:
      return "macos.systemDefault operation has an empty key"
    if not isSystemDefaultDomain(op.sdDomain):
      return "macos.systemDefault domain '" & op.sdDomain &
        "' does not resolve to a plist under /Library/Preferences/"
    # The type flag flows into the elevated `defaults write` command
    # line — it MUST be one of the fixed `defaults` type flags so a
    # `type = "...; <cmd>"` profile cannot reach arbitrary root exec.
    if not isSafeDefaultsTypeFlag(op.sdValueType):
      return "macos.systemDefault value type '" & op.sdValueType &
        "' is not one of the accepted `defaults write` type flags"
  of pokSystemdSystemUnit:
    if not isSafeUnitName(op.suName):
      return "systemd.systemUnit name '" & op.suName &
        "' is not a safe single-segment unit file name"
  of pokLaunchdSystemDaemon:
    if not isSafeDaemonLabel(op.sdaLabel):
      return "launchd.systemDaemon label '" & op.sdaLabel &
        "' is not a safe single-segment label"
    # The label flows into the elevated `launchctl print|bootout
    # system/<label>` command lines — restrict it to the conservative
    # reverse-DNS identifier charset so a `label = "x; <cmd>"` profile
    # cannot reach arbitrary root execution. `isSafeDaemonLabel` above
    # blocks only path separators; this also rejects shell
    # metacharacters and whitespace.
    if not isSafeLaunchdLabel(op.sdaLabel):
      return "launchd.systemDaemon label '" & op.sdaLabel &
        "' contains characters outside the launchd identifier charset " &
        "(letters, digits, '.', '-', '_')"
    if not op.sdaDestroy and op.sdaProgramArgs.len == 0:
      return "launchd.systemDaemon '" & op.sdaLabel &
        "' has an empty ProgramArguments array"
  of pokFsSystemFile:
    # The `${PROGRAMDATA}` root is supplied by the driver at apply
    # time (it is not a fixed path); the closed-set validator checks
    # only the fixed POSIX allowlist plus a `..`-segment guard. A
    # `${PROGRAMDATA}`-rooted path that the fixed roots reject here is
    # re-validated against the live `${PROGRAMDATA}` by the driver.
    let scopeErr = systemFileScopeError(op.sfPath)
    if scopeErr.len > 0 and op.sfPath.find("..") >= 0:
      return scopeErr
    if op.sfPath.strip().len == 0:
      return "fs.systemFile operation has an empty path"
    # External-source mutual exclusion: defence-in-depth against a
    # malformed plan reaching the broker. The template + validator on
    # the profile side already reject this; we re-check here so the
    # closed-set boundary stays self-contained.
    let nonEmptySources = (if op.sfContent.len > 0: 1 else: 0) +
                          (if op.sfSourceUrl.len > 0: 1 else: 0) +
                          (if op.sfSourceLocal.len > 0: 1 else: 0)
    if nonEmptySources > 1:
      return "fs.systemFile '" & op.sfPath &
        "' declares more than one content source — at most one of " &
        "`sfContent`, `sfSourceUrl`, `sfSourceLocal` may be non-empty"
    if op.sfSourceUrl.len > 0 and op.sfSha256.len == 0:
      return "fs.systemFile '" & op.sfPath &
        "' sets `sfSourceUrl` but no `sfSha256` — the URL fetch " &
        "requires a digest to verify against"
    if op.sfSha256.len > 0 and op.sfSourceUrl.len == 0:
      return "fs.systemFile '" & op.sfPath &
        "' sets `sfSha256` but no `sfSourceUrl` — the digest is only " &
        "meaningful when paired with a URL fetch"
    if op.sfSha256.len > 0:
      # Lowercase 64-char hex check. Mirrors the format the BLAKE3
      # driver emits for `posixDigestHexOfText`.
      if op.sfSha256.len != 64:
        return "fs.systemFile '" & op.sfPath &
          "' sfSha256 must be a 64-character lowercase hex digest " &
          "(got " & $op.sfSha256.len & " chars)"
      for ch in op.sfSha256:
        if ch notin {'0'..'9', 'a'..'f'}:
          return "fs.systemFile '" & op.sfPath &
            "' sfSha256 must be a 64-character lowercase hex digest " &
            "(contains non-hex character '" & $ch & "')"
  of pokFsSystemDirectory:
    if op.fsdPath.strip().len == 0:
      return "fs.systemDirectory operation has an empty path"
    # `systemDirectoryScopeError` rejects only the structural-escape
    # case (`..` segments); the closed system-root vs Windows-install-
    # root choice is re-validated by the driver at apply time against
    # the live `${PROGRAMDATA}`. We mirror the `fs.systemFile` arm: a
    # path that fails the fixed allowlist AND contains `..` is refused
    # here as an out-of-scope sandbox escape.
    let scopeErr = systemDirectoryScopeError(op.fsdPath)
    if scopeErr.len > 0 and op.fsdPath.find("..") >= 0:
      return scopeErr
    if op.fsdAclPresent:
      if op.fsdAclOwner.len > 0 and not isSafeAclPrincipal(op.fsdAclOwner):
        return "fs.systemDirectory aclOwner '" & op.fsdAclOwner &
          "' contains characters outside the principal charset " &
          "(letters, digits, '\\', ' ', '.', '-', '_', '@')"
      if op.fsdAclInheritance.len > 0 and
         op.fsdAclInheritance notin DirectoryAclInheritanceModes:
        return "fs.systemDirectory aclInheritance '" &
          op.fsdAclInheritance & "' is not one of " &
          DirectoryAclInheritanceModes.join(" / ")
      if not op.fsdDestroy and op.fsdAclEntries.len == 0:
        return "fs.systemDirectory '" & op.fsdPath &
          "' has aclPresent=true but an empty aclEntries list — a " &
          "non-destroy apply with ACL management must declare at " &
          "least one ACE"
      for ace in op.fsdAclEntries:
        if not isSafeAclEntry(ace):
          return "fs.systemDirectory aclEntry '" & ace &
            "' is not a safe `<principal>:<perms>` ACE spec " &
            "(principal must be in the NTAccount / SID charset; perms " &
            "must use only icacls permission codes, '(', ')', ',', ' ')"
  of pokEnvSystemVariable:
    if op.evName.len == 0:
      return "env.systemVariable operation has an empty variable name"
  of pokPasswdUser:
    if op.puName.strip().len == 0:
      return "passwd.user operation has an empty user name"
    for ch in op.puName:
      if ch in {'/', ':', ' ', '\t', '\n'}:
        return "passwd.user name '" & op.puName &
          "' contains an invalid character"
  of pokOsTimezone:
    if op.tzIana.strip().len == 0:
      return "os.timezone operation has an empty IANA timezone name"
    if not isSafeIanaTimezone(op.tzIana):
      return "os.timezone IANA name '" & op.tzIana &
        "' contains characters outside the IANA charset (letters, " &
        "digits, '/', '_', '-', '+', '.')"
    # The Windows side maps IANA -> Windows name via the embedded
    # table; fail-closed at validation time so an unmapped name never
    # reaches `tzutil`. The POSIX side passes the IANA name verbatim
    # to `timedatectl` / `systemsetup`, but those tools fail-closed
    # on an unrecognized name so we accept any IANA-shaped string
    # off-Windows. Defence-in-depth: also accept on Windows when the
    # mapping table covers it.
    if not isMappedIanaTimezone(op.tzIana):
      return "os.timezone IANA name '" & op.tzIana &
        "' is not in the embedded IANA -> Windows timezone mapping " &
        "table; add it to IanaToWindowsTzTable in os_system_parse.nim " &
        "or use a mapped IANA name"
  of pokOsHostname:
    if op.hostnameName.strip().len == 0:
      return "os.hostname operation has an empty hostname"
    if not isSafeHostname(op.hostnameName):
      return "os.hostname '" & op.hostnameName &
        "' is not a valid RFC 1123 hostname (letters, digits, '-' " &
        "only; 1-63 octets; no leading/trailing '-')"
  of pokLinuxSysctl:
    if op.sysctlKey.strip().len == 0:
      return "linux.sysctl operation has an empty key"
    if not isSafeSysctlKey(op.sysctlKey):
      return "linux.sysctl key '" & op.sysctlKey &
        "' contains characters outside the sysctl-key charset " &
        "(letters, digits, '.', '-', '_', '/')"
    if not isSafeSysctlValue(op.sysctlValue):
      return "linux.sysctl value for key '" & op.sysctlKey &
        "' contains a newline — a sysctl drop-in file is one " &
        "key=value line, so a newline in the value would corrupt the file"
    if op.sysctlFilename.len > 0:
      if not isSafeDropInBasename(op.sysctlFilename):
        return "linux.sysctl filename '" & op.sysctlFilename &
          "' is not a safe single-segment basename (letters, digits, " &
          "'.', '-', '_'; no '/', '..', or shell metacharacter)"
      if not op.sysctlFilename.endsWith(".conf"):
        return "linux.sysctl filename '" & op.sysctlFilename &
          "' must end with '.conf' (sysctl.d convention)"
  of pokLinuxUdevRule:
    if not isSafeDropInBasename(op.udevName):
      return "linux.udevRule name '" & op.udevName &
        "' is not a safe single-segment basename (letters, digits, " &
        "'.', '-', '_'; no '/', '..', or shell metacharacter)"
    if not op.udevName.endsWith(".rules"):
      return "linux.udevRule name '" & op.udevName &
        "' must end with '.rules' (udev convention)"
  of pokLinuxPolkitRule:
    if not isSafeDropInBasename(op.polkitName):
      return "linux.polkitRule name '" & op.polkitName &
        "' is not a safe single-segment basename (letters, digits, " &
        "'.', '-', '_'; no '/', '..', or shell metacharacter)"
    if not op.polkitName.endsWith(".rules"):
      return "linux.polkitRule name '" & op.polkitName &
        "' must end with '.rules' (polkit convention)"
  of pokLinuxTmpfilesRule:
    if not isSafeDropInBasename(op.tmpfilesName):
      return "linux.tmpfilesRule name '" & op.tmpfilesName &
        "' is not a safe single-segment basename (letters, digits, " &
        "'.', '-', '_'; no '/', '..', or shell metacharacter)"
    if not op.tmpfilesName.endsWith(".conf"):
      return "linux.tmpfilesRule name '" & op.tmpfilesName &
        "' must end with '.conf' (tmpfiles.d convention)"
  of pokLinuxSudoersRule:
    if not isSafeDropInBasename(op.sudoersName):
      return "linux.sudoersRule name '" & op.sudoersName &
        "' is not a safe single-segment basename (letters, digits, " &
        "'.', '-', '_'; no '/', '..', or shell metacharacter)"
    # sudoers convention: NO extension. A `.` in the name would cause
    # sudo's `sudoers.d` parser to silently SKIP the file — defence-in-
    # depth refusal here surfaces the typo at validation time rather
    # than at the next privileged operation.
    if op.sudoersName.contains('.'):
      return "linux.sudoersRule name '" & op.sudoersName &
        "' must not contain '.' — sudo silently ignores sudoers.d " &
        "files with a '.' in the basename"
  of pokPasswdGroup:
    if not isSafePosixUserOrGroupName(op.pgName):
      return "passwd.group name '" & op.pgName &
        "' is not a valid POSIX group name (letters, digits, '.', " &
        "'-', '_'; no leading '-')"
    if not isSafeGid(op.pgGid):
      return "passwd.group gid '" & op.pgGid &
        "' is not a non-negative decimal integer"
    for m in op.pgMembers:
      if not isSafePosixUserOrGroupName(m):
        return "passwd.group member '" & m &
          "' is not a valid POSIX user name (letters, digits, '.', " &
          "'-', '_'; no leading '-')"
  of pokLinuxNixDaemonSetting:
    if not isSafeNixDaemonKey(op.nixKey):
      return "linux.nixDaemonSetting key '" & op.nixKey &
        "' contains characters outside the Nix-key charset " &
        "(letters, digits, '-', '_')"
    if not isSafeNixDaemonValue(op.nixValue):
      return "linux.nixDaemonSetting value for key '" & op.nixKey &
        "' contains a newline — a nix.conf drop-in entry is one " &
        "key=value line, so a newline in the value would corrupt the file"
    if op.nixFilename.len > 0:
      if not isSafeDropInBasename(op.nixFilename):
        return "linux.nixDaemonSetting filename '" & op.nixFilename &
          "' is not a safe single-segment basename (letters, digits, " &
          "'.', '-', '_'; no '/', '..', or shell metacharacter)"
      if not op.nixFilename.endsWith(".conf"):
        return "linux.nixDaemonSetting filename '" & op.nixFilename &
          "' must end with '.conf' (nix.conf.d convention)"
  of pokSystemdSystemTimer:
    if not isSafeUnitName(op.stName):
      return "systemd.systemTimer name '" & op.stName &
        "' is not a safe single-segment unit file name"
    if not op.stName.endsWith(".timer"):
      return "systemd.systemTimer name '" & op.stName &
        "' must end with '.timer' (systemd timer convention)"
  of pokLinuxFirewallRule:
    if not isSafeNftChain(op.lfwChain):
      return "linux.firewallRule chain '" & op.lfwChain &
        "' is not a `<family> <table> <chain>` triple in the " &
        "conservative nftables identifier charset (letters, digits, " &
        "'-', '_')"
    if not isSafeNftRuleName(op.lfwName):
      return "linux.firewallRule name '" & op.lfwName &
        "' contains characters outside the rule-identifier charset " &
        "(letters, digits, '.', '-', '_')"
    if op.lfwProtocol notin LinuxFirewallProtocols:
      return "linux.firewallRule protocol '" & op.lfwProtocol &
        "' is not one of " & LinuxFirewallProtocols.join(" / ")
    if op.lfwDirection.len > 0 and
       op.lfwDirection notin LinuxFirewallDirections:
      return "linux.firewallRule direction '" & op.lfwDirection &
        "' is not one of " & LinuxFirewallDirections.join(" / ")
    if op.lfwAction notin LinuxFirewallActions:
      return "linux.firewallRule action '" & op.lfwAction &
        "' is not one of " & LinuxFirewallActions.join(" / ")
    if op.lfwLocalPort.len > 0 and not isSafeNftPort(op.lfwLocalPort):
      return "linux.firewallRule localPort '" & op.lfwLocalPort &
        "' is not a port number, port range, comma list, or 'any'"
    # tcp / udp need a port; icmp / icmpv6 do not. Enforce the
    # protocol-port pairing so a `protocol = tcp` rule with no port
    # never reaches `nft` (which would reject it with a less-useful
    # diagnostic).
    if op.lfwProtocol in ["tcp", "udp"] and not op.lfwDestroy:
      if op.lfwLocalPort.strip().len == 0 or
         op.lfwLocalPort.strip() == "any":
        return "linux.firewallRule for protocol '" & op.lfwProtocol &
          "' requires a non-empty localPort (port number, port " &
          "range, or comma list); 'any' is not accepted by `nft " &
          "add rule <chain> " & op.lfwProtocol & " dport ...`"
  of pokLinuxNixosSystemModule:
    if not isSafeDropInBasename(op.nixosModuleName):
      return "linux.nixosSystemModule name '" & op.nixosModuleName &
        "' is not a safe single-segment basename (letters, digits, " &
        "'.', '-', '_'; no '/', '..', or shell metacharacter)"
    if not op.nixosModuleName.endsWith(".nix"):
      return "linux.nixosSystemModule name '" & op.nixosModuleName &
        "' must end with '.nix' (Nix module convention)"
  of pokMacosDarwinSystemModule:
    if not isSafeDropInBasename(op.darwinModuleName):
      return "macos.darwinSystemModule name '" & op.darwinModuleName &
        "' is not a safe single-segment basename (letters, digits, " &
        "'.', '-', '_'; no '/', '..', or shell metacharacter)"
    if not op.darwinModuleName.endsWith(".nix"):
      return "macos.darwinSystemModule name '" & op.darwinModuleName &
        "' must end with '.nix' (Nix module convention)"
  of pokLinuxFhsSandbox:
    # `fsbBinPath` must be a POSIX absolute path (leading `/`). The
    # driver does NOT canonicalize — `..` collapse / symlink resolve
    # is the catalog adapter's job upstream — but unambiguous
    # bind-mount targets require a leading `/`.
    if op.fsbBinPath.strip().len == 0:
      return "linux.fhsSandbox operation has an empty binPath"
    if not isPosixAbsolutePath(op.fsbBinPath):
      return "linux.fhsSandbox binPath '" & op.fsbBinPath &
        "' is not an absolute path (must start with '/')"
    if containsNul(op.fsbBinPath):
      return "linux.fhsSandbox binPath contains a NUL byte (refused — " &
        "execve would reject the argv element)"
    # M1 takes the FIRST FHS-tree-root entry as the single composed
    # prefix. A non-destroy apply MUST therefore declare at least one
    # entry. A multi-entry compose is accepted at parse time (each
    # entry is shape-checked) but the driver currently only uses
    # entries[0]; M2 will add the overlay / sequential-bind compose.
    if not op.fsbDestroy and op.fsbFhsTreeRoots.len == 0:
      return "linux.fhsSandbox '" & op.address &
        "' has an empty fhsTreeRoots list (a non-destroy apply must " &
        "declare at least one realized FHS-tree-root prefix; M1 uses " &
        "the first entry, M2 will compose multiple)"
    for root in op.fsbFhsTreeRoots:
      if root.strip().len == 0:
        return "linux.fhsSandbox '" & op.address &
          "' has an empty fhsTreeRoots entry"
      if not isPosixAbsolutePath(root):
        return "linux.fhsSandbox fhsTreeRoots entry '" & root &
          "' is not an absolute path (must start with '/')"
      if containsNul(root):
        return "linux.fhsSandbox fhsTreeRoots entry contains a NUL " &
          "byte (refused — execve would reject the argv element)"
    # `fsbArgv` passes through `execve` as an argv vector — NOT a
    # shell command. Shell metacharacter filtering is therefore
    # unnecessary by construction. The only filter is a NUL byte
    # refusal because `execve` rejects NUL in argv with EFAULT and a
    # typed parse error gives the operator a useful diagnostic.
    for arg in op.fsbArgv:
      if containsNul(arg):
        return "linux.fhsSandbox argv entry contains a NUL byte " &
          "(refused — execve would reject the argv element)"
  of pokInlineExecCall:
    # Windows-System-Resources Phase E: closed-set posture for the
    # elevated build-engine inline-exec hand-off. The plan stores the
    # LITERAL `@FILE:<path>` argv entries (no secret in the plan); the
    # @FILE expander runs at apply time in the broker dispatch path.
    # We refuse here:
    #   * an empty executable                — argv[0] is required;
    #   * NUL bytes in any closed field      — `execve` would reject
    #                                          them, and a typed
    #                                          parse error is a much
    #                                          better diagnostic;
    #   * a malformed `@FILE:` token         — the codec boundary is
    #                                          the place to catch a
    #                                          relative-path / empty-
    #                                          payload mistake (the
    #                                          apply-time expander
    #                                          re-checks as defence-
    #                                          in-depth);
    #   * an environment entry missing `=`   — `NAME=VALUE` is the
    #                                          only shape the spawn
    #                                          primitive accepts.
    if op.iecExecutable.strip().len == 0:
      return "reprobuild.inlineExecCall operation has an empty executable"
    if containsNul(op.iecExecutable):
      return "reprobuild.inlineExecCall executable contains a NUL byte " &
        "(refused — exec primitives reject NUL in argv)"
    for idx, arg in op.iecArguments:
      if containsNul(arg):
        return "reprobuild.inlineExecCall arguments[" & $idx &
          "] contains a NUL byte (refused — exec primitives reject " &
          "NUL in argv)"
      if isArgFileToken(arg):
        let tokenErr = argFileTokenError(arg)
        if tokenErr.len > 0:
          return "reprobuild.inlineExecCall arguments[" & $idx & "] " &
            tokenErr
    if containsNul(op.iecWorkingDirectory):
      return "reprobuild.inlineExecCall workingDirectory contains a " &
        "NUL byte (refused)"
    for idx, entry in op.iecEnvironment:
      if containsNul(entry):
        return "reprobuild.inlineExecCall environment[" & $idx &
          "] contains a NUL byte (refused — exec primitives reject " &
          "NUL in env)"
      let eq = entry.find('=')
      if eq <= 0:
        return "reprobuild.inlineExecCall environment[" & $idx &
          "] '" & entry & "' is not a NAME=VALUE entry (the broker " &
          "spawn primitive requires the conventional shape)"
    for idx, refName in op.iecToolIdentityRefs:
      if containsNul(refName):
        return "reprobuild.inlineExecCall toolIdentityRefs[" & $idx &
          "] contains a NUL byte (refused)"
      if refName.strip().len == 0:
        return "reprobuild.inlineExecCall toolIdentityRefs[" & $idx &
          "] is empty (each ref must name a `uses:` tool)"
  return ""

# ---------------------------------------------------------------------------
# HKLM key-string helpers for the `windows.registryValue scope=system`
# planner. A `system.nim` profile authors `key = r"HKLM\SOFTWARE\..."`;
# the planner strips the hive prefix and confirms the key is an HKLM
# key (the only hive the privileged registry driver writes).
# ---------------------------------------------------------------------------

proc isHklmKey*(key: string): bool =
  ## True when `key` names an `HKLM` (HKEY_LOCAL_MACHINE) registry
  ## key. The privileged `windows.registryValue` operation is built
  ## ONLY for an HKLM key — an HKCU key is a home-scope M68 resource.
  let u = key.toUpperAscii()
  u.startsWith("HKLM\\") or u.startsWith("HKLM/") or
    u.startsWith("HKEY_LOCAL_MACHINE\\") or
    u.startsWith("HKEY_LOCAL_MACHINE/")

proc stripHklmPrefix*(key: string): string =
  ## Return the subkey path under HKLM, with the `HKLM\` /
  ## `HKEY_LOCAL_MACHINE\` prefix removed and separators normalized
  ## to backslash. Raises `ValueError` if `key` is not an HKLM key.
  if not isHklmKey(key):
    raise newException(ValueError,
      "windows.registryValue scope=system requires an HKLM key, got '" &
      key & "'")
  var rest: string
  let u = key.toUpperAscii()
  if u.startsWith("HKEY_LOCAL_MACHINE"):
    rest = key[len("HKEY_LOCAL_MACHINE") .. ^1]
  else:
    rest = key[len("HKLM") .. ^1]
  if rest.len > 0 and (rest[0] == '\\' or rest[0] == '/'):
    rest = rest[1 .. ^1]
  return rest.replace('/', '\\')
