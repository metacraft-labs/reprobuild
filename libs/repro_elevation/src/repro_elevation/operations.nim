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

import ./os_system_parse
import ./posix_system_parse
import ./system_value

type
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
      serviceName*: string
      serviceStartType*: string
      serviceRunning*: bool
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
      ## Write `sfContent` to `sfPath` — an absolute path that MUST
      ## be under a recognized system directory (`/etc/`,
      ## `/usr/local/etc/`, `${PROGRAMDATA}`). `sfDestroy` selects the
      ## delete direction.
      sfPath*: string
      sfContent*: string
      sfDestroy*: bool
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
  of pokWindowsVsInstaller: true
  of pokWindowsFirewallRule: true
  of pokMacosSystemDefault: true
  of pokSystemdSystemUnit: true
  of pokLaunchdSystemDaemon: true
  of pokFsSystemFile: true
  of pokEnvSystemVariable: true
  of pokPasswdUser: true
  of pokOsTimezone: true
  of pokOsHostname: true
  of pokLinuxSysctl: true

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
  of $pokWindowsVsInstaller: pokWindowsVsInstaller
  of $pokWindowsFirewallRule: pokWindowsFirewallRule
  of $pokMacosSystemDefault: pokMacosSystemDefault
  of $pokSystemdSystemUnit: pokSystemdSystemUnit
  of $pokLaunchdSystemDaemon: pokLaunchdSystemDaemon
  of $pokFsSystemFile: pokFsSystemFile
  of $pokEnvSystemVariable: pokEnvSystemVariable
  of $pokPasswdUser: pokPasswdUser
  of $pokOsTimezone: pokOsTimezone
  of $pokOsHostname: pokOsHostname
  of $pokLinuxSysctl: pokLinuxSysctl
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
