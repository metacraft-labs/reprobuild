## The M69 Phase-A system-scope profile model + parser.
##
## Per the M69 phasing, Phase A's `repro infra apply` operates on a
## hand-authored `system.nim` profile — exactly as M63 applied a
## home profile before M61-style profile-editing existed. The
## `repro system add/remove/list/...` profile-editing family is
## deferred to a later phase.
##
## The profile is a small declarative format: one resource per
## stanza, `kind { key = value ... }`. It is parsed by a PURE
## function (`parseSystemProfile`) so the parser is unit-tested
## cross-platform. Each parsed `SystemResource` maps to exactly one
## typed `PrivilegedOperation` (the M81 closed set, extended by M69).
##
## Phase A supports the four Windows system-scope resources; Phase B
## adds the fifth, `windows.vsInstaller`:
##
##   windows.registryValue { key=... name=... kind=... value=... }
##   windows.optionalFeature { name=... }
##   windows.capability { name=... }
##   windows.service { name=... startType=... state=... }
##   windows.vsInstaller { edition=... channel=... installPath=...
##                         workloads=[...] components=[...] strict=... }
##
## `fs.systemFile`, `env.systemVariable`, the POSIX surface, and
## `macos.systemDefault` are deferred — the parser rejects them with a
## clear "deferred to a later phase" diagnostic.

import std/[strutils, tables]

import repro_elevation
import repro_dsl_stdlib/packages/apt_closure

import ./errors

type
  SystemResourceKind* = enum
    srkWindowsRegistryValue = "windows.registryValue"
    srkWindowsOptionalFeature = "windows.optionalFeature"
    srkWindowsCapability = "windows.capability"
    srkWindowsService = "windows.service"
    srkWindowsScheduledTask = "windows.scheduledTask"
    srkWindowsVsInstaller = "windows.vsInstaller"
    srkWindowsFirewallRule = "windows.firewallRule"
    srkWindowsAcl = "windows.acl"
    srkMacosSystemDefault = "macos.systemDefault"
    srkSystemdSystemUnit = "systemd.systemUnit"
    srkLaunchdSystemDaemon = "launchd.systemDaemon"
    srkFsSystemFile = "fs.systemFile"
    srkFsSystemDirectory = "fs.systemDirectory"
    srkEnvSystemVariable = "env.systemVariable"
    srkPasswdUser = "passwd.user"
    srkOsTimezone = "os.timezone"
    srkOsHostname = "os.hostname"
    srkLinuxSysctl = "linux.sysctl"
    srkLinuxUdevRule = "linux.udevRule"
    srkLinuxPolkitRule = "linux.polkitRule"
    srkLinuxTmpfilesRule = "linux.tmpfilesRule"
    srkLinuxSudoersRule = "linux.sudoersRule"
    srkPasswdGroup = "passwd.group"
    srkLinuxNixDaemonSetting = "linux.nixDaemonSetting"
    srkSystemdSystemTimer = "systemd.systemTimer"
    srkLinuxFirewallRule = "linux.firewallRule"
    srkLinuxNixosSystemModule = "linux.nixosSystemModule"
    srkMacosDarwinSystemModule = "macos.darwinSystemModule"
    srkLinuxFhsSandbox = "linux.fhsSandbox"
    srkLinuxDpkgDiversion = "linux.dpkgDiversion"
    srkSystemdUnitState = "systemd.unitState"
    srkLinuxAddOnTool = "linux.addOnTool"
    srkSystemdSystemDropIn = "systemd.systemDropIn"
    srkLinuxSysusersEntry = "linux.sysusersEntry"

  ResourceDependency* = tuple[kind: string, name: string]
    ## A single `depends_on` edge: `"kind:name"` parsed into its two
    ## components. The match against another resource in the same
    ## profile uses `kind == $resource.kind` AND a kind-specific name
    ## comparison (`name == resource.<primary-name-field>`), so the
    ## syntax stays uniform across every resource kind.

  SystemResource* = object
    ## One declared system-scope resource. `address` is the stable
    ## plan call-site identity; it defaults to a derivation of the
    ## real-world target when the stanza omits an explicit `address`.
    ##
    ## `dependsOn` carries the user-declared dependency edges from the
    ## stanza's optional `depends_on = ["kind:name", ...]` attribute
    ## (M82 Phase B). The planner combines these EXPLICIT edges with
    ## IMPLICIT edges inferred from the shared
    ## `producer_consumer_map.ProducerConsumerMap` to build the apply
    ## dependency graph and topologically order the emitted plan.
    ## Empty seq is the common case — most resources have no declared
    ## dependencies.
    address*: string
    dependsOn*: seq[ResourceDependency]
    case kind*: SystemResourceKind
    of srkWindowsRegistryValue:
      regKey*: string                ## "HKLM\\..."
      regName*: string
      regValueKind*: SystemRegistryValueKind
      regValueLiteral*: string
    of srkWindowsOptionalFeature:
      featureName*: string
      featureEnabled*: bool          ## desired: enabled (default true)
    of srkWindowsCapability:
      capabilityName*: string
      capabilityInstalled*: bool     ## desired: installed (default true)
    of srkWindowsService:
      serviceName*: string
      serviceStartType*: string
      serviceRunning*: bool
      serviceDisplayName*: string
        ## Windows-System-Resources Phase B: optional service
        ## `DISPLAY_NAME`. Empty (default) means "derived from `name`"
        ## — the driver does NOT reconfigure the display name.
      serviceBinPath*: string
        ## Phase B: optional service `BINARY_PATH_NAME`. Empty
        ## (default) means "reuse the SCM's current `sc qc` value" —
        ## the driver does NOT reconfigure the binPath. A non-empty
        ## value drives `sc.exe config <name> binPath= "<value>"`.
      serviceRecoveryActions*: seq[WindowsServiceRecoverySpec]
        ## Phase B: optional failure-recovery policy. Empty seq
        ## (default) means "leave the SCM's failure policy untouched";
        ## a non-empty seq drives `sc.exe failure <name> actions= ...`.
        ## The driver consumes up to three (action, delayMs) slots in
        ## declaration order.
      serviceRecoveryResetSeconds*: int
        ## Phase B: optional failure-count reset window. `0` (default)
        ## means "do not emit `reset= ` to `sc.exe failure`"; a
        ## positive value drives `sc.exe failure <name> reset= <secs>`.
    of srkWindowsScheduledTask:
      ## Windows-System-Resources Phase C: a Task Scheduler entry.
      ## Identity is the fully-qualified `wstTaskName`; the schedule +
      ## principal + executable + enabled flag are observable live
      ## state. `wst*` field prefix avoids collisions with the
      ## `serviceX` / `sd*` / `sda*` families already in this object.
      wstTaskName*: string
      wstExecutable*: string
      wstArguments*: seq[string]
      wstWorkingDirectory*: string
      wstRunAsUser*: string
      wstRunWithHighestPrivileges*: bool
      wstSchedule*: ScheduledTaskScheduleSpec
        ## Discriminated trigger union — the `repro_elevation`
        ## `ScheduledTaskScheduleSpec` mirrors the front-end
        ## `repro_profile.types.ScheduleSpec` byte-for-byte (closed
        ## set of variants + lower-case wire tokens); the dep-inversion
        ## stays clean because `repro_elevation` does NOT import
        ## `repro_profile`.
      wstEnabled*: bool
    of srkWindowsVsInstaller:
      vsEdition*: string
      vsChannel*: string
      vsInstallPath*: string
      vsWorkloads*: seq[string]
      vsComponents*: seq[string]
      vsStrict*: bool
    of srkWindowsFirewallRule:
      fwName*: string
      fwDisplayName*: string
      fwProtocol*: string
      fwDirection*: string
      fwAction*: string
      fwLocalPort*: string
      fwEnabled*: bool
    of srkWindowsAcl:
      aclPath*: string
      aclOwner*: string
      aclEntries*: seq[string]
      aclInheritanceMode*: string         ## "" => "enabled"
    of srkMacosSystemDefault:
      sdDomain*: string
      sdKey*: string
      sdValueType*: string             ## `defaults` type flag, e.g. -string
      sdValueLiteral*: string
      sdRestartTarget*: string
    of srkSystemdSystemUnit:
      suName*: string                  ## unit file name, e.g. foo.service
      suContent*: string
      suEnabled*: bool                 ## desired: enabled --now (default true)
      suAptClosureLock*: string        ## a `package(apt)` closure lock, or ""
                                       ## (Add-On spec §8.3; `apt_closure`)
      suRestartHeld*: bool             ## `restartIfChanged = false` (§7.3)
      suCollision*: string
        ## Add-on mode's opt-in when a package already provides the unit
        ## (ReproOS-Add-On-Mode §4.3): "" (refuse), `dropIn` (write the
        ## content as a drop-in of the package's unit, so the package's
        ## unit stays visible) or `replace` (an /etc unit of the same name
        ## shadows the package's; recorded in the ledger). Outside add-on
        ## mode the field is carried and ignored.
      suDropInName*: string
        ## With `collision = dropIn`: the drop-in is
        ## `/etc/systemd/system/<unit>.d/50-repro-<dropInName>.conf`.
        ## Defaults to `addon`. One path segment of `[A-Za-z0-9._-]`.
      suStopHeld*: bool
        ## `stopOnRemoval = false` (ReproOS Add-On Mode §7.3): when the
        ## unit leaves the profile its file is removed but the running
        ## instance is left alone (it ends when it ends). Default: a
        ## removed unit is stopped first.
      suReloadIfChanged*: bool
        ## `reloadIfChanged = true` (§7.3): when only a resource the unit
        ## `depends_on` changed (its unit file, drop-ins and closure are
        ## unchanged), the running instance is reloaded (`ExecReload=`)
        ## instead of restarted.
      suExclusive*: bool
        ## `exclusive = true` (§7.3): two instances of this service must
        ## never run at once (a validator client signing with one key).
        ## The switch stops and confirms the old instance has exited
        ## before the new one starts, and refuses the apply
        ## (`EAddOnExclusiveOverlap`) when it cannot. A unit whose
        ## rendered file carries `X-Repro-Exclusive=true` is exclusive
        ## too, so an adopted hand-written unit can declare it.
      suHealthCheck*: string
        ## `healthCheck = "<check>"` (ReproOS-Add-On-Mode §7.5): what must
        ## hold after the add-on switch starts the unit, within the
        ## profile's `confirmTimeout`, for the generation to be committed;
        ## otherwise the switch reverts to the previous generation. One of
        ## `active`, `tcp:<loopback>:<port>`, `http://<loopback>:<port>/…`
        ## or `exec:/repro/store/…` (see `parseHealthCheck`). Outside
        ## add-on mode the field is carried and ignored.
      suCredentials*: seq[string]
        ## `credentials = ["<name>", ...]` (ReproOS-Add-On-Mode §10.3): the
        ## secrets this unit reads through systemd credentials. Each name
        ## must be declared by a `secrets.secretFile` of the unit's
        ## service (`credentialServiceOf`), and renders as
        ## `LoadCredential=<name>:/run/repro/secrets/<service>/<name>` in
        ## the unit's `[Service]` section (`renderedSystemUnitContent`), so
        ## the service reads it from `$CREDENTIALS_DIRECTORY` and its
        ## account never gets access to the shared directory.
    of srkLaunchdSystemDaemon:
      sdaLabel*: string
      sdaProgramArgs*: seq[string]
      sdaRunAtLoad*: bool
    of srkFsSystemFile:
      sfPath*: string
      sfContent*: string
      sfSourceUrl*: string
        ## External content source: URL fetched at apply time on the
        ## controller side. Empty when the file is content-inline or
        ## sourced from a local path. When non-empty, `sfSha256` MUST
        ## also be set (the validator enforces this).
      sfSha256*: string
        ## Lowercase 64-char hex BLAKE3 digest of the bytes the
        ## controller expects `sfSourceUrl` to serve. The driver
        ## compares the fetched bytes' digest against this string and
        ## raises `EProtocol` on mismatch BEFORE asking the broker to
        ## write.
      sfSourceLocal*: string
        ## External content source: path on the controller side
        ## re-read on every apply (so a between-step edit between two
        ## applies of the same plan lands).
        ##
        ## These three external-source fields are mutually exclusive
        ## with each other AND with `sfContent`: at most one of
        ## `sfContent` / `sfSourceUrl` / `sfSourceLocal` may be
        ## non-empty. The validator rejects an over-specified profile
        ## with `ESystemProfileInvalid`.
      sfCollision*: string
        ## Add-on mode's opt-in when a package owns the path
        ## (ReproOS-Add-On-Mode §4.3): "" (refuse) or `divert` (a local
        ## dpkg diversion sends the package's copy to `<path>.distrib`
        ## first, recorded and undone on removal). Outside add-on mode the
        ## field is carried and ignored.
    of srkFsSystemDirectory:
      dirPath*: string
      dirAclPresent*: bool                ## false => ACL is unmanaged
      dirAclOwner*: string                ## "" leaves ownership unchanged
      dirAclEntries*: seq[string]         ## icacls /grant-form ACE specs
      dirAclInheritance*: string          ## "" => "enabled"
    of srkEnvSystemVariable:
      evName*: string
      evContribution*: seq[string]
      evIsPathList*: bool              ## PATH-list contribution semantics
    of srkPasswdUser:
      puName*: string
      puHome*: string
      puShell*: string
      puGroups*: seq[string]
    of srkOsTimezone:
      tzIana*: string
    of srkOsHostname:
      hostnameName*: string
    of srkLinuxSysctl:
      sysctlKey*: string
      sysctlValue*: string
      sysctlFilename*: string             ## "" => auto-derived
    of srkLinuxUdevRule:
      udevName*: string                   ## basename, must end `.rules`
      udevContent*: string
    of srkLinuxPolkitRule:
      polkitName*: string                 ## basename, must end `.rules`
      polkitContent*: string
    of srkLinuxTmpfilesRule:
      tmpfilesName*: string               ## basename, must end `.conf`
      tmpfilesContent*: string
      tmpfilesApplyNow*: bool             ## `systemd-tmpfiles --create` now
    of srkLinuxSudoersRule:
      sudoersName*: string                ## basename, no extension
      sudoersContent*: string
    of srkPasswdGroup:
      pgName*: string                     ## group name
      pgGid*: string                      ## "" => unpinned
      pgMembers*: seq[string]             ## additive-only members
    of srkLinuxNixDaemonSetting:
      nixKey*: string
      nixValue*: string
      nixFilename*: string                ## "" => auto-derived
    of srkSystemdSystemTimer:
      stName*: string                     ## unit file name, must end `.timer`
      stContent*: string
      stEnabled*: bool                    ## desired: enabled (default true)
      stRunning*: bool                    ## desired: active (default true)
    of srkLinuxFirewallRule:
      lfwChain*: string                   ## "<family> <table> <chain>"
      lfwName*: string                    ## stable marker
      lfwProtocol*: string                ## tcp/udp/icmp/icmpv6
      lfwDirection*: string               ## inbound/outbound (informational)
      lfwLocalPort*: string               ## port number / range
      lfwAction*: string                  ## accept/drop/reject
    of srkLinuxNixosSystemModule:
      nixosModuleName*: string            ## basename, must end `.nix`
      nixosModuleContent*: string         ## verbatim Nix expression
    of srkMacosDarwinSystemModule:
      darwinModuleName*: string           ## basename, must end `.nix`
      darwinModuleContent*: string        ## verbatim Nix expression
    of srkLinuxFhsSandbox:
      fsbBinPath*: string                 ## absolute path inside the FHS view
      fsbFhsTreeRoots*: seq[string]       ## realized prefixes composed into /
      fsbArgv*: seq[string]               ## additional argv after fsbBinPath
    of srkLinuxDpkgDiversion:
      ddPath*: string                     ## the package-owned path diverted
    of srkSystemdUnitState:
      usName*: string                     ## a unit the add-on does NOT own
      usEnabled*: bool                    ## desired: enabled (default true)
      usRunning*: bool                    ## desired: active (default true)
    of srkLinuxAddOnTool:
      atCommand*: string                  ## wrapper name under /etc/repro/bin
      atAptClosureLock*: string           ## the closure the command runs from
      atProgram*: string                  ## FHS path inside the closure
    of srkSystemdSystemDropIn:
      ## A drop-in for a unit the profile does NOT own (a distribution
      ## unit), ReproOS Add-On Mode §4.1 `dropIn` class:
      ## `/etc/systemd/system/<diUnit>.d/50-repro-<diName>.conf`. A
      ## changed drop-in restarts an active `diUnit` (§7.3) unless
      ## `restartIfChanged = false`.
      diUnit*: string                     ## the unit it modifies
      diName*: string                     ## `<name>` of `50-repro-<name>.conf`
      diContent*: string
      diRestartHeld*: bool                ## `restartIfChanged = false`
    of srkLinuxSysusersEntry:
      ## A system account or group for a service, declared as one
      ## sysusers.d(5) entry in `/etc/sysusers.d/repro-<seName>.conf` and
      ## applied with `systemd-sysusers <file>` (§4.1 `sysusers` class).
      ## `passwd.user` / `passwd.group` stay for accounts that need
      ## `useradd` semantics. An account the add-on created is never
      ## deleted (a reused UID would hand its files to a new owner).
      seName*: string
      seKind*: string                     ## "user" (default) or "group"
      seId*: string                       ## pinned UID / GID, "" => chosen
      seDescription*: string              ## GECOS, users only
      seHome*: string                     ## "" => systemd's default (/)
      seShell*: string                    ## "" => systemd's default (nologin)

  AddOnSettings* = object
    ## The profile-wide `addOn { ... }` stanza of ReproOS add-on mode
    ## (ReproOS-Add-On-Mode §4.4). It is not a resource: it declares what
    ## the profile's resources may touch, and every plan shows it.
    declared*: bool
      ## True when the profile carries an `addOn` stanza at all.
    managedEtcPrefixes*: seq[string]
      ## The `/etc` prefixes the profile intends to own, as written
      ## (`/etc/vaultwarden/` for a subtree, `/etc/issue.net` for one
      ## file). `/etc/repro/` is always managed and never needs listing.
      ## `fs.systemFile` and `linux.dpkgDiversion` paths outside them are
      ## refused in add-on mode with `EAddOnOutOfScope`.
    confirmTimeoutSec*: int
      ## `confirmTimeout = <seconds>` (§7.5): how long the switch waits,
      ## from the moment its start step finished, for every unit's
      ## `healthCheck` to pass. 0 when not declared: the default applies
      ## (`DefaultConfirmTimeoutSec`).

  SecretFileDecl* = object
    ## A `secrets.secretFile { service = "<s>"  name = "<n>" }` declaration
    ## (ReproOS-Add-On-Mode §8.3, §10.3). The generation needs the sealed
    ## entry `<s>/<n>` of the host's retained envelope materialised as
    ## `/run/repro/secrets/<s>/<n>`; a unit of the service `<s>` reads it
    ## by naming `<n>` in its `credentials`. It is not a resource: it has
    ## no driver, no ledger entry and nothing under `/etc` -- the secret
    ## itself never appears in a profile, only the name of the entry that
    ## carries it -- so it is carried beside the resources, like the
    ## `addOn` stanza, and the add-on's secrets layer
    ## (`repro_addon/addon_secrets`) gives it its meaning.
    service*: string
    name*: string

  SystemProfile* = object
    ## The parsed `system.nim` — an ordered list of resources. The
    ## order is the apply order.
    resources*: seq[SystemResource]
    addOn*: AddOnSettings
    secretFiles*: seq[SecretFileDecl]
      ## The `secrets.secretFile` declarations, in profile order.

proc realWorldIdentity*(r: SystemResource): string =
  ## Stable identity of the real-world object the resource targets.
  case r.kind
  of srkWindowsRegistryValue:
    r.regKey & "\\" & r.regName
  of srkWindowsOptionalFeature:
    "feature:" & r.featureName
  of srkWindowsCapability:
    "capability:" & r.capabilityName
  of srkWindowsService:
    "service:" & r.serviceName
  of srkWindowsScheduledTask:
    "scheduledTask:" & r.wstTaskName
  of srkWindowsVsInstaller:
    "vsInstaller:" & r.vsEdition &
      (if r.vsInstallPath.len > 0: "@" & r.vsInstallPath else: "")
  of srkWindowsFirewallRule:
    "firewallRule:" & r.fwName
  of srkWindowsAcl:
    "acl:" & r.aclPath
  of srkMacosSystemDefault:
    "systemDefault:" & r.sdDomain & ":" & r.sdKey
  of srkSystemdSystemUnit:
    "systemUnit:" & r.suName
  of srkLaunchdSystemDaemon:
    "systemDaemon:" & r.sdaLabel
  of srkFsSystemFile:
    "systemFile:" & r.sfPath
  of srkFsSystemDirectory:
    "systemDirectory:" & r.dirPath
  of srkEnvSystemVariable:
    "systemVariable:" & r.evName
  of srkPasswdUser:
    "user:" & r.puName
  of srkOsTimezone:
    "timezone:" & r.tzIana
  of srkOsHostname:
    "hostname:" & r.hostnameName
  of srkLinuxSysctl:
    "sysctl:" & r.sysctlKey
  of srkLinuxUdevRule:
    "udevRule:" & r.udevName
  of srkLinuxPolkitRule:
    "polkitRule:" & r.polkitName
  of srkLinuxTmpfilesRule:
    "tmpfilesRule:" & r.tmpfilesName
  of srkLinuxSudoersRule:
    "sudoersRule:" & r.sudoersName
  of srkPasswdGroup:
    "group:" & r.pgName
  of srkLinuxNixDaemonSetting:
    "nixDaemonSetting:" & r.nixKey
  of srkSystemdSystemTimer:
    "systemTimer:" & r.stName
  of srkLinuxFirewallRule:
    "firewallRule:" & r.lfwName
  of srkLinuxNixosSystemModule:
    "nixosSystemModule:" & r.nixosModuleName
  of srkMacosDarwinSystemModule:
    "darwinSystemModule:" & r.darwinModuleName
  of srkLinuxFhsSandbox:
    "fhsSandbox:" & r.fsbBinPath
  of srkLinuxDpkgDiversion:
    "dpkgDiversion:" & r.ddPath
  of srkSystemdUnitState:
    "unitState:" & r.usName
  of srkLinuxAddOnTool:
    "addOnTool:" & r.atCommand
  of srkSystemdSystemDropIn:
    "systemDropIn:" & r.diUnit & "/" & r.diName
  of srkLinuxSysusersEntry:
    "sysusersEntry:" & r.seName

proc resourceKindTag*(r: SystemResource): string =
  ## The string form of the resource's kind — the LEFT half of the
  ## `"kind:name"` pair used in `depends_on` and in the producer ->
  ## consumer map (M82 Phase B). Matches `$r.kind` exactly because the
  ## enum string values ARE the profile-syntax kind tags (e.g.
  ## `"windows.capability"`); this proc names the convention.
  $r.kind

proc resourceName*(r: SystemResource): string =
  ## The "primary name" of the resource — the RIGHT half of the
  ## `"kind:name"` pair used in `depends_on` and in the producer ->
  ## consumer map (M82 Phase B). For most kinds this is the natural
  ## name attribute (e.g. `windows.capability.name`,
  ## `windows.service.name`); for the registry kind it is the
  ## fully-qualified `<key>\<valueName>` since neither sub-field alone
  ## identifies the resource. `windows.vsInstaller` uses its edition.
  case r.kind
  of srkWindowsRegistryValue:
    r.regKey & "\\" & r.regName
  of srkWindowsOptionalFeature: r.featureName
  of srkWindowsCapability: r.capabilityName
  of srkWindowsService: r.serviceName
  of srkWindowsScheduledTask: r.wstTaskName
  of srkWindowsVsInstaller: r.vsEdition
  of srkWindowsFirewallRule: r.fwName
  of srkWindowsAcl: r.aclPath
  of srkMacosSystemDefault: r.sdDomain & ":" & r.sdKey
  of srkSystemdSystemUnit: r.suName
  of srkLaunchdSystemDaemon: r.sdaLabel
  of srkFsSystemFile: r.sfPath
  of srkFsSystemDirectory: r.dirPath
  of srkEnvSystemVariable: r.evName
  of srkPasswdUser: r.puName
  of srkOsTimezone: r.tzIana
  of srkOsHostname: r.hostnameName
  of srkLinuxSysctl: r.sysctlKey
  of srkLinuxUdevRule: r.udevName
  of srkLinuxPolkitRule: r.polkitName
  of srkLinuxTmpfilesRule: r.tmpfilesName
  of srkLinuxSudoersRule: r.sudoersName
  of srkPasswdGroup: r.pgName
  of srkLinuxNixDaemonSetting: r.nixKey
  of srkSystemdSystemTimer: r.stName
  of srkLinuxFirewallRule: r.lfwName
  of srkLinuxNixosSystemModule: r.nixosModuleName
  of srkMacosDarwinSystemModule: r.darwinModuleName
  of srkLinuxFhsSandbox: r.fsbBinPath
  of srkLinuxDpkgDiversion: r.ddPath
  of srkSystemdUnitState: r.usName
  of srkLinuxAddOnTool: r.atCommand
  of srkSystemdSystemDropIn: r.diUnit & "/" & r.diName
  of srkLinuxSysusersEntry: r.seName

# ---------------------------------------------------------------------------
# The declarative-format parser. Pure — no filesystem access.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Quoting. A field value is a double-quoted string whose only escape is a
# DOUBLED quote: `""` inside the quotes stands for one `"` character, as in
# a Nim raw string literal (`r"a""b"` is `a"b`;
# https://nim-lang.org/docs/manual.html#lexical-analysis-raw-string-literals).
# Nothing else is decoded: a backslash, a `#`, a `{` / `}` and a newline are
# all literal, so a Windows path (`HKLM\SOFTWARE\...`), a unit file and a
# shell script are written verbatim.
#
# Why this escape and not `\"`: the format has always been written with
# single, undecoded backslashes, and every stored generation embeds its
# profile text (`GenerationEnvelope.profileText`, which `repro system
# rollback` re-parses). A backslash escape would change the meaning of text
# already on disk (`"\\server\share"`). No value could contain a `"` before
# this rule existed, so a doubled quote never occurred inside a value and
# every existing text parses to exactly what it did. The scanners that track
# quote state (`stripComments`, the brace walk, the assignment splitter and
# `parseListLiteral`) toggle once per `"`, so a doubled quote leaves their
# state unchanged and needs no special case; only `unquote` decodes it.
# ---------------------------------------------------------------------------

proc quoteSystemValue*(value: string): string =
  ## Render `value` as a quoted field value of the `system.nim` text form.
  ## Every byte string round-trips: `unquote(quoteSystemValue(v)) == v`.
  ## This is the ONE encoder: the editor (`intent.renderStanza`) and the
  ## compiled-profile renderer (`renderSystemProfileToText`) both call it.
  "\"" & value.replace("\"", "\"\"") & "\""

proc stripComments*(text: string): string =
  ## Blank out every `#`-comment in `text`, carrying the quote state across
  ## newlines, so a `#` inside a quoted value — on its first line or any
  ## later one — is value text, not a comment.
  ##
  ## A comment's characters are replaced by spaces rather than removed, so
  ## an offset into the result is an offset into `text`; the editor maps
  ## stanza bounds back to lines through `systemProfileStanzaLineSpans`.
  ##
  ## This replaces a per-line pass that restarted with `inQuote = false` on
  ## every line. It dropped `#` lines from a multi-line value and cut a
  ## value at an in-value `#` (`ExecStart=/bin/echo a#b` became
  ## `ExecStart=/bin/echo a`), and reported nothing (reprobuild-pm issue
  ## 2026-10-30-system-profile-text-parser-drops-hash-text-inside-multi-line-quoted-values).
  result = newString(text.len)
  var inQuote = false
  var inComment = false
  for i, c in text:
    if inComment:
      if c in {'\n', '\r'}:
        inComment = false
        result[i] = c
      else:
        result[i] = ' '
    elif c == '"':
      inQuote = not inQuote
      result[i] = c
    elif c == '#' and not inQuote:
      inComment = true
      result[i] = ' '
    else:
      result[i] = c

proc unquote(v: string): string =
  ## The value a field's raw text denotes. A quoted value loses its
  ## surrounding quotes and has each doubled quote decoded (see
  ## `quoteSystemValue`); a bare token (`true`, a list) is returned stripped.
  let t = v.strip()
  if t.len >= 2 and t[0] == '"' and t[^1] == '"':
    return t[1 ..< t.len - 1].replace("\"\"", "\"")
  return t

proc parseBoolField(name, raw: string): bool =
  case raw.strip().toLowerAscii()
  of "true", "yes", "on", "1": true
  of "false", "no", "off", "0": false
  else:
    raiseSystemProfileInvalid("field '" & name & "' is not a boolean: '" &
      raw & "'")

proc splitFieldAssignments(body: string): seq[string] =
  ## Split a brace body into `key = value` assignment tokens. An
  ## assignment ends at a newline OR at the start of the next
  ## `<ident> =` — so `{ name = "X" }` and multi-line bodies both
  ## parse. A quoted value may itself contain spaces; a `[...]` list
  ## value may itself span lines and carry commas, so the splitter
  ## tracks bracket depth and never splits inside a list. Comment
  ## stripping happens globally upstream.
  var assignments: seq[string]
  var token = ""
  var inQuote = false
  var bracketDepth = 0

  proc flush() =
    if token.strip().len > 0:
      assignments.add(token.strip())
    token = ""

  var i = 0
  while i < body.len:
    let c = body[i]
    if c == '"':
      inQuote = not inQuote
      token.add(c)
      inc i
    elif inQuote:
      token.add(c)
      inc i
    elif c == '[':
      inc bracketDepth
      token.add(c)
      inc i
    elif c == ']':
      if bracketDepth > 0: dec bracketDepth
      token.add(c)
      inc i
    elif bracketDepth > 0:
      # Inside a list literal: copy verbatim (commas, newlines, all).
      token.add(c)
      inc i
    elif c in {'\r', '\n'} and token.strip().len > 0:
      # A newline ends an assignment (the multi-line stanza form).
      flush()
      inc i
    elif c in {' ', '\t'} and token.strip().len > 0 and token.contains('='):
      # The compact single-line stanza form: an unquoted run of
      # `<ws>* <ident> <ws>* =` begins a new assignment.
      var j = i
      while j < body.len and body[j] in {' ', '\t'}: inc j
      var k = j
      while k < body.len and (body[k].isAlphaNumeric or body[k] == '_'):
        inc k
      var m = k
      while m < body.len and body[m] in {' ', '\t'}: inc m
      if k > j and m < body.len and body[m] == '=':
        flush()
        i = j
      else:
        token.add(c)
        inc i
    else:
      token.add(c)
      inc i
  flush()
  return assignments

proc parseListLiteral*(raw: string): seq[string] =
  ## Parse a `[a, b, c]` list literal into its string elements. Each
  ## element may be a bare identifier or a double-quoted string;
  ## whitespace and newlines around elements are stripped. An empty
  ## `[]` yields an empty seq. Used by `windows.vsInstaller`'s
  ## `workloads` / `components` fields.
  let t = raw.strip()
  if t.len < 2 or t[0] != '[' or t[^1] != ']':
    raiseSystemProfileInvalid("expected a '[...]' list literal, got: '" &
      raw & "'")
  let inner = t[1 ..< t.len - 1]
  var elem = ""
  var inQuote = false

  proc flushElem(items: var seq[string]) =
    let v = elem.strip()
    if v.len > 0:
      items.add(unquote(v))
    elem = ""

  for c in inner:
    if c == '"':
      inQuote = not inQuote
      elem.add(c)
    elif c == ',' and not inQuote:
      flushElem(result)
    else:
      elem.add(c)
  flushElem(result)

proc parseDependsOn(kindTag, raw: string): seq[ResourceDependency] =
  ## Parse a `depends_on = ["kind:name", "kind:name", ...]` list value
  ## into its typed dependency edges (M82 Phase B). Each entry must be
  ## `kind:name` with a non-empty `kind` and a non-empty `name`; the
  ## FIRST `:` separates the two, so a name containing a `:` (e.g. an
  ## HKLM key path) still parses correctly. The shared
  ## `parseListLiteral` does the surface-level `[...] -> seq[string]`
  ## split; this proc validates each entry's shape and raises
  ## `ESystemProfileInvalid` with a clear message on a malformed entry
  ## (the offending text is echoed back so the operator can find it).
  let items = parseListLiteral(raw)
  for item in items:
    let t = item.strip()
    if t.len == 0:
      raiseSystemProfileInvalid("resource '" & kindTag &
        "' has an empty 'depends_on' entry")
    let colon = t.find(':')
    if colon <= 0 or colon == t.len - 1:
      raiseSystemProfileInvalid("resource '" & kindTag &
        "' has a malformed 'depends_on' entry '" & t &
        "' — expected 'kind:name' (e.g. " &
        "'windows.capability:OpenSSH.Server~~~~0.0.1.0')")
    let depKind = t[0 ..< colon].strip()
    let depName = t[colon + 1 .. ^1].strip()
    if depKind.len == 0 or depName.len == 0:
      raiseSystemProfileInvalid("resource '" & kindTag &
        "' has a malformed 'depends_on' entry '" & t &
        "' — both kind and name must be non-empty")
    result.add((kind: depKind, name: depName))

const
  SecretsMutation {.strdefine: "reproAddonMutation".} = ""
    ## The add-on's compile-time falsifying mutations (``repro_addon/
    ## mutations``): ``secrets-on-disk`` moves the secrets root onto the
    ## root filesystem consistently -- materialiser and ``LoadCredential=``
    ## alike -- so the services still run and only the disk scan can tell.
  SecretsRunRoot* = when SecretsMutation == "secrets-on-disk":
                      "/var/lib/repro/secrets"
                    else:
                      "/run/repro/secrets"
    ## Where the add-on materialises plaintext secrets (a tmpfs, §10.3).
  SecretsOrderingUnit* = "repro-addon-reassert.service"
    ## The unit that re-materialises secrets at boot (§7.7 step 3). A
    ## unit that loads credentials is ordered after it, so it never starts
    ## at boot before its secrets exist; on a host without it (full
    ## ReproOS) an `After=` on a unit that does not exist orders nothing.

proc isSafeSecretComponent*(s: string): bool =
  ## One path segment of `[A-Za-z0-9._-]`, at most 64 bytes, not starting
  ## with `.` (so never `.`, `..`, or the materialiser's hidden temporary
  ## names): a secret's service and name both become a path component
  ## under `/run/repro/secrets` and part of a `LoadCredential=` line.
  if s.len == 0 or s.len > 64 or s[0] == '.':
    return false
  for c in s:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_'}:
      return false
  true

proc secretEntryPath*(service, name: string): string =
  ## The sealed entry a `secrets.secretFile` names: `<service>/<name>`, the
  ## same relative path it is materialised at under `SecretsRunRoot`. The
  ## entry itself names the one service that may load it (CRED-3).
  service & "/" & name

proc credentialServiceOf*(unitName: string): string =
  ## The secrets service of a unit: its name without `.service`, or "" when
  ## the unit cannot load credentials (not a `.service`, a template
  ## instance, or a name that is not a safe component).
  if not unitName.endsWith(".service"):
    return ""
  let stem = unitName[0 ..< unitName.len - ".service".len]
  if isSafeSecretComponent(stem): stem else: ""

proc credentialLines*(unitName: string; credentials: openArray[string]):
    seq[string] =
  ## The `[Service]` lines the `credentials` of `unitName` render to.
  let svc = credentialServiceOf(unitName)
  for c in credentials:
    result.add("LoadCredential=" & c & ":" & SecretsRunRoot & "/" & svc &
               "/" & c)

proc renderedSystemUnitContent*(r: SystemResource): string =
  ## The unit-file bytes a `systemd.systemUnit` resource installs. Without
  ## a closure lock that is `suContent` verbatim. With one, the unit's
  ## `[Service]` section gains the closure's `BindReadOnlyPaths=` /
  ## `InaccessiblePaths=` lines (Add-On spec §8.3 item 5), naming the
  ## prefix the lock pins under the Add-On store root — the path the host's
  ## driver realises before it writes the unit. A malformed lock or a unit
  ## that cannot carry the binding is an `ESystemProfileInvalid`.
  ##
  ## With `credentials`, the `[Service]` section also gains one
  ## `LoadCredential=` line per credential (`credentialLines`) and the
  ## `[Unit]` section an `After=` the boot-time secrets step
  ## (`SecretsOrderingUnit`), ReproOS-Add-On-Mode §10.3.
  doAssert r.kind == srkSystemdSystemUnit
  var content = r.suContent
  if r.suAptClosureLock.len > 0:
    try:
      content = renderUnitForAptClosureLock(r.suContent, r.suAptClosureLock,
        unitName = r.suName)
    except EAptClosureLock, EAptClosureUnit:
      raiseSystemProfileInvalid("systemd.systemUnit '" & r.suName & "': " &
        getCurrentExceptionMsg())
  if r.suCredentials.len == 0:
    return content
  if credentialServiceOf(r.suName).len == 0:
    raiseSystemProfileInvalid("systemd.systemUnit '" & r.suName &
      "' names credentials, but only a plain `<service>.service` unit " &
      "(no template instance) can load them")
  var seenCred: seq[string]
  for c in r.suCredentials:
    if not isSafeSecretComponent(c):
      raiseSystemProfileInvalid("systemd.systemUnit '" & r.suName &
        "' credential '" & c & "' must be one path segment of letters, " &
        "digits, '.', '-' or '_', at most 64 bytes, not starting with '.'")
    if c in seenCred:
      raiseSystemProfileInvalid("systemd.systemUnit '" & r.suName &
        "' names the credential '" & c & "' twice")
    seenCred.add(c)
  var outLines: seq[string]
  var inService = false
  var serviceSeen = false
  var unitSeen = false
  for l in content.split('\n'):
    let t = l.strip()
    if t.startsWith("[") and t.endsWith("]"):
      if inService:
        # Close the [Service] section with the credential lines, before the
        # next section starts (blank lines stay where they were).
        var tail: seq[string]
        while outLines.len > 0 and outLines[^1].strip().len == 0:
          tail.add(outLines.pop())
        outLines.add(credentialLines(r.suName, r.suCredentials))
        for i in countdown(tail.high, 0): outLines.add(tail[i])
      inService = t == "[Service]"
      if inService: serviceSeen = true
      outLines.add(l)
      if t == "[Unit]" and not unitSeen:
        unitSeen = true
        outLines.add("After=" & SecretsOrderingUnit)
      continue
    outLines.add(l)
  if inService:
    var tail: seq[string]
    while outLines.len > 0 and outLines[^1].strip().len == 0:
      tail.add(outLines.pop())
    outLines.add(credentialLines(r.suName, r.suCredentials))
    for i in countdown(tail.high, 0): outLines.add(tail[i])
  if not serviceSeen:
    raiseSystemProfileInvalid("systemd.systemUnit '" & r.suName &
      "' names credentials but has no [Service] section")
  if not unitSeen:
    outLines = @["[Unit]", "After=" & SecretsOrderingUnit, ""] & outLines
  outLines.join("\n")

proc checkUnitStateResource*(r: SystemResource) =
  ## The refusals both the text parser and the DSL adapter apply to a
  ## `systemd.unitState` (ReproOS Add-On Mode §4.1): the name must be a
  ## unit name systemd would accept, since the resource owns nothing it
  ## could validate against.
  doAssert r.kind == srkSystemdUnitState
  if not isSafeUnitName(r.usName) or not hasKnownUnitSuffix(r.usName):
    raiseSystemProfileInvalid("systemd.unitState name '" & r.usName &
      "' is not a safe unit name with a unit-type suffix " &
      "(e.g. avahi-daemon.service)")

proc checkAddOnToolResource*(r: SystemResource) =
  ## The refusals both paths apply to a `linux.addOnTool` (§4.1): a safe
  ## command name (it becomes a file under `/etc/repro/bin`), an absolute
  ## program path inside the closure, and a lock that parses — at plan
  ## time, not on the host at apply time.
  doAssert r.kind == srkLinuxAddOnTool
  if not isSafeAddOnToolCommand(r.atCommand):
    raiseSystemProfileInvalid("linux.addOnTool command '" & r.atCommand &
      "' is not a safe command name (letters, digits, '.', '-', '_', '+')")
  if not isPosixAbsolutePath(r.atProgram):
    raiseSystemProfileInvalid("linux.addOnTool '" & r.atCommand &
      "': program '" & r.atProgram & "' must be an absolute path inside " &
      "the closure (e.g. /usr/bin/" & r.atCommand & ")")
  try:
    discard parseAptClosureLock(r.atAptClosureLock)
  except EAptClosureLock:
    raiseSystemProfileInvalid("linux.addOnTool '" & r.atCommand & "': " &
      getCurrentExceptionMsg())

proc checkDropInResource*(r: SystemResource) =
  ## The refusals both profile paths apply to a `systemd.systemDropIn`
  ## (ReproOS Add-On Mode §4.1): a unit name systemd would accept and a
  ## fragment name that is one safe path segment, so the drop-in cannot
  ## land outside `/etc/systemd/system/<unit>.d/`.
  doAssert r.kind == srkSystemdSystemDropIn
  if not isSafeUnitName(r.diUnit) or not hasKnownUnitSuffix(r.diUnit):
    raiseSystemProfileInvalid("systemd.systemDropIn unit '" & r.diUnit &
      "' is not a safe unit name with a unit-type suffix " &
      "(e.g. cron.service)")
  if not isSafeFragmentName(r.diName):
    raiseSystemProfileInvalid("systemd.systemDropIn name '" & r.diName &
      "' must be one path segment of letters, digits, '.', '-' or '_'")

proc checkSysusersEntryResource*(r: SystemResource) =
  ## The refusals both profile paths apply to a `linux.sysusersEntry`
  ## (§4.1): a name sysusers.d(5) accepts, a kind of `user` or `group`, a
  ## numeric id when pinned, and no field that could break out of its
  ## line in the fragment (a newline, a quote in the description).
  doAssert r.kind == srkLinuxSysusersEntry
  if not isSafePosixUserOrGroupName(r.seName):
    raiseSystemProfileInvalid("linux.sysusersEntry name '" & r.seName &
      "' is not a safe account name (letters, digits, '.', '-', '_'; " &
      "must start with a letter or '_')")
  if r.seKind notin ["user", "group"]:
    raiseSystemProfileInvalid("linux.sysusersEntry '" & r.seName &
      "' kind '" & r.seKind & "' is not one of user / group")
  if r.seId.len > 0 and not isSafeGid(r.seId):
    raiseSystemProfileInvalid("linux.sysusersEntry '" & r.seName &
      "' id '" & r.seId & "' is not a numeric id")
  for (field, value) in [("description", r.seDescription), ("home", r.seHome),
                         ("shell", r.seShell)]:
    if '\n' in value or '\r' in value or '"' in value or
        (value.len > 0 and value.splitWhitespace().len != 1 and
         field != "description"):
      raiseSystemProfileInvalid("linux.sysusersEntry '" & r.seName & "' " &
        field & " may not contain a newline, a double quote" &
        (if field != "description": " or whitespace" else: ""))
  if r.seKind == "group" and (r.seDescription.len > 0 or r.seHome.len > 0 or
                              r.seShell.len > 0):
    raiseSystemProfileInvalid("linux.sysusersEntry '" & r.seName &
      "' is a group: description, home and shell apply to users only")
  for (field, value) in [("home", r.seHome), ("shell", r.seShell)]:
    if value.len > 0 and not isPosixAbsolutePath(value):
      raiseSystemProfileInvalid("linux.sysusersEntry '" & r.seName & "' " &
        field & " '" & value & "' must be an absolute path")

proc sysusersEntryContent*(r: SystemResource): string =
  ## The fragment bytes a `linux.sysusersEntry` installs
  ## (`sysusersFragmentContent`): what the driver writes and digests.
  doAssert r.kind == srkLinuxSysusersEntry
  sysusersFragmentContent(r.seKind, r.seName, r.seId, r.seDescription,
                          r.seHome, r.seShell)

proc unitContentDeclaresExclusive*(content: string): bool =
  ## `X-Repro-Exclusive=true|yes|1` in the `[Unit]` section (ReproOS Add-On
  ## Mode §7.3: "a unit whose X- metadata says exclusive = true"). systemd
  ## ignores `X-` keys, so the marker travels in the unit file itself and
  ## an adopted hand-written unit can carry it.
  var inUnit = false
  for raw in content.splitLines():
    let line = raw.strip()
    if line.startsWith("["):
      inUnit = line == "[Unit]"
      continue
    if not inUnit or line.len == 0 or line[0] in {'#', ';'}:
      continue
    let eq = line.find('=')
    if eq < 0: continue
    if line[0 ..< eq].strip() == "X-Repro-Exclusive":
      return line[eq + 1 .. ^1].strip().toLowerAscii() in ["true", "yes", "1", "on"]
  false

proc isExclusiveUnit*(r: SystemResource): bool =
  ## The resource's `exclusive` field, or the marker in its content.
  r.kind == srkSystemdSystemUnit and
    (r.suExclusive or unitContentDeclaresExclusive(r.suContent))

proc checkUnitStateConflicts*(resources: openArray[SystemResource]) =
  ## A unit name may not be declared both as a `systemd.unitState` (a unit
  ## the add-on does NOT own) and as a `systemd.systemUnit` (one it writes):
  ## the two would converge the same unit from opposite ownership stances
  ## (ReproOS Add-On Mode §4.1). Both profile paths call this once the
  ## resource list is complete.
  var owned: seq[string]
  for r in resources:
    if r.kind == srkSystemdSystemUnit:
      owned.add(r.suName)
  for r in resources:
    if r.kind == srkSystemdUnitState and r.usName in owned:
      raiseSystemProfileInvalid("unit '" & r.usName & "' is declared both " &
        "as systemd.unitState (not owned) and as systemd.systemUnit " &
        "(owned); drop the systemd.unitState resource — a unit the " &
        "profile writes is enabled through its own `enabled` field")

proc checkPasswdPrimaryGroups*(resources: openArray[SystemResource]) =
  ## A `passwd.user` that lists its own name in `groups` gets that group as
  ## its primary group (`useradd --gid`), which the driver does only for a
  ## group the profile itself declares: the profile must carry a
  ## `passwd.group` of the same name (System-Profile-And-Infra-Apply.md,
  ## `passwd.user`). Without it the account would join, as its primary, a
  ## group that happens to exist on the host and that nothing in the
  ## profile owns.
  var groups: seq[string]
  for r in resources:
    if r.kind == srkPasswdGroup:
      groups.add(r.pgName)
  for r in resources:
    if r.kind == srkPasswdUser and
        r.puName in r.puGroups and r.puName notin groups:
      raiseSystemProfileInvalid("passwd.user '" & r.puName & "' lists " &
        "its own name in groups, which makes '" & r.puName & "' its " &
        "primary group; declare passwd.group '" & r.puName & "' in the " &
        "same profile, or drop it from groups")

# ---------------------------------------------------------------------------
# ReproOS add-on mode's profile surface (ReproOS-Add-On-Mode §4.3, §4.4):
# the per-resource `collision` opt-in and the profile-wide `addOn` stanza.
# They are parsed here, with the rest of the format, so a hand-written
# profile and one the add-on composes are read by the same code; the
# add-on layer (`repro_addon`) gives them their meaning.
# ---------------------------------------------------------------------------

const
  AddOnStanzaTag* = "addOn"
  SecretFileStanzaTag* = "secrets.secretFile"
    ## The `secrets.secretFile` declaration (`SecretFileDecl`). Like the
    ## `addOn` stanza it is not a resource stanza.
  UnitCollisionOptIns* = ["dropIn", "replace"]
    ## `collision` values a `systemd.systemUnit` may declare.
  FileCollisionOptIns* = ["divert"]
    ## `collision` values an `fs.systemFile` may declare.
  AddOnClassDirectories* = ["/etc/systemd/system/", "/etc/sysusers.d/",
                            "/etc/tmpfiles.d/", "/etc/sysctl.d/"]
    ## Directories reached through their own add-on classes (units,
    ## sysusers, tmpfiles, sysctl). They are never managed prefixes, and
    ## an `fs.systemFile` below them is out of scope.
  UnitSearchDirectories* = ["/etc/systemd/system.control/",
                            "/etc/systemd/system.attached/",
                            "/etc/systemd/user/", "/etc/systemd/user.control/",
                            "/etc/xdg/systemd/user/",
                            "/etc/systemd/system-generators/",
                            "/etc/systemd/user-generators/",
                            "/etc/systemd/system-preset/",
                            "/etc/systemd/user-preset/"]
    ## Directories below /etc that systemd reads units, generators or
    ## presets from (systemd.unit(5) "Unit File Load Path" for the system
    ## and user managers, systemd.generator(7), systemd.preset(5)) other
    ## than /etc/systemd/system, which is a class directory. A file there
    ## defines, shadows or enables a unit (or runs as a generator at boot)
    ## past the unit and drop-in classes' collision rules, so none of them
    ## may be a managed prefix or contain one.
  AlwaysManagedEtcPrefix* = "/etc/repro/"
    ## The add-on's own directory: managed without being declared.

const
  DefaultConfirmTimeoutSec* = 60
    ## §7.5's default `confirmTimeout` (deploy-rs uses 30 s).
  MaxConfirmTimeoutSec* = 3600

type
  HealthCheckKind* = enum
    hcActive = "active"    ## the unit itself reaches ActiveState=active
    hcTcp = "tcp"          ## a TCP connection to a loopback port succeeds
    hcHttp = "http"        ## an HTTP GET on loopback answers 2xx
    hcExec = "exec"        ## a command in the store exits 0

  HealthCheckSpec* = object
    ## A parsed `healthCheck` value. Probes are loopback only (§7.5: "a
    ## TCP or HTTP probe on loopback"), so a check can never make the
    ## switch reach out to the network, and a command must live in the
    ## store, so what decides a commit is itself part of a closure.
    kind*: HealthCheckKind
    host*: string          ## tcp / http: `127.0.0.1`, `::1` or `localhost`
    port*: int             ## tcp / http
    path*: string          ## http: the request target, starting with `/`
    argv*: seq[string]     ## exec: the command and its arguments

const
  HealthCheckStoreRoot* = "/repro/store/"
  LoopbackHosts = ["127.0.0.1", "::1", "localhost"]

proc parseHostPort(text, what: string): tuple[host: string; port: int] =
  ## `127.0.0.1:80`, `localhost:80` or `[::1]:80`.
  var host, portText: string
  if text.startsWith("["):
    let close = text.find(']')
    if close < 0 or close + 1 >= text.len or text[close + 1] != ':':
      raiseSystemProfileInvalid(what & ": malformed address '" & text & "'")
    host = text[1 ..< close]
    portText = text[close + 2 .. ^1]
  else:
    let colon = text.rfind(':')
    if colon <= 0:
      raiseSystemProfileInvalid(what & ": '" & text & "' needs host:port")
    host = text[0 ..< colon]
    portText = text[colon + 1 .. ^1]
  if host notin LoopbackHosts:
    raiseSystemProfileInvalid(what & ": '" & host & "' is not a loopback " &
      "address; health checks probe loopback only (127.0.0.1, ::1, localhost)")
  var port = 0
  try:
    port = parseInt(portText)
  except ValueError:
    raiseSystemProfileInvalid(what & ": port '" & portText & "' is not a number")
  if port notin 1 .. 65535:
    raiseSystemProfileInvalid(what & ": port " & $port & " is out of range")
  (host, port)

proc parseHealthCheck*(value: string): HealthCheckSpec =
  ## The `healthCheck` field of a `systemd.systemUnit` (ReproOS-Add-On-Mode
  ## §7.5). Strict: anything else is refused at parse time, so a mistyped
  ## check can never silently mean "no check".
  let what = "healthCheck '" & value & "'"
  if value == "active":
    return HealthCheckSpec(kind: hcActive)
  if value.startsWith("tcp:"):
    let (h, p) = parseHostPort(value[4 .. ^1], what)
    return HealthCheckSpec(kind: hcTcp, host: h, port: p)
  if value.startsWith("http://"):
    let rest = value["http://".len .. ^1]
    let slash = rest.find('/')
    let authority = if slash < 0: rest else: rest[0 ..< slash]
    let path = if slash < 0: "/" else: rest[slash .. ^1]
    for c in path:
      if ord(c) <= 32 or ord(c) >= 127:
        raiseSystemProfileInvalid(what & ": the path carries a space or " &
          "a control character")
    let (h, p) = parseHostPort(authority, what)
    return HealthCheckSpec(kind: hcHttp, host: h, port: p, path: path)
  if value.startsWith("exec:"):
    let argv = value[5 .. ^1].splitWhitespace()
    if argv.len == 0 or not argv[0].startsWith(HealthCheckStoreRoot) or
        "/../" in argv[0] or argv[0].endsWith("/.."):
      raiseSystemProfileInvalid(what & ": the command must be an " &
        "absolute path below " & HealthCheckStoreRoot)
    return HealthCheckSpec(kind: hcExec, argv: argv)
  raiseSystemProfileInvalid(what & " is not one of `active`, " &
    "`tcp:<loopback>:<port>`, `http://<loopback>:<port>/<path>` or " &
    "`exec:" & HealthCheckStoreRoot & "…`")

proc parseCollisionField*(kindTag, value: string;
                          allowed: openArray[string]): string =
  ## The `collision` field of a stanza: "" when absent, else one of the
  ## opt-ins the kind allows. Any other value is refused at parse time,
  ## so a misspelt opt-in cannot silently fall back to the default
  ## refusal (or, worse, to an overwrite).
  if value.len == 0:
    return ""
  if value notin allowed:
    raiseSystemProfileInvalid(kindTag & " collision '" & value &
      "' is not one of " & allowed.join(" / "))
  value

proc isSafeDropInName*(name: string): bool =
  ## One path segment of `[A-Za-z0-9._-]`, not `.` or `..`.
  if name.len == 0 or name == "." or name == "..":
    return false
  for c in name:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_'}:
      return false
  true

proc parseSecretFileStanza*(body: string): SecretFileDecl =
  ## The `secrets.secretFile { service = "<s>"  name = "<n>" }` stanza.
  for assignment in splitFieldAssignments(body):
    let eq = assignment.find('=')
    if eq < 0:
      raiseSystemProfileInvalid("expected 'key = value' in '" &
        SecretFileStanzaTag & "', got: '" & assignment & "'")
    let key = assignment[0 ..< eq].strip()
    let value = unquote(assignment[eq + 1 .. ^1].strip())
    case key
    of "service": result.service = value
    of "name": result.name = value
    else:
      raiseSystemProfileInvalid("'" & SecretFileStanzaTag &
        "' has no field '" & key & "' (known: service, name; the secret " &
        "itself never appears in a profile: it arrives sealed, §10.3)")
  for (what, v) in [("service", result.service), ("name", result.name)]:
    if not isSafeSecretComponent(v):
      raiseSystemProfileInvalid("'" & SecretFileStanzaTag & "' " & what &
        " '" & v & "' must be one path segment of letters, digits, '.', " &
        "'-' or '_', at most 64 bytes, not starting with '.'")

proc checkSecretDeclarations*(p: SystemProfile) =
  ## The cross-stanza refusals of the secrets surface (§10.3), shared by the
  ## text parser and the DSL adapter: one declaration per entry, and every
  ## credential a unit names declared for that unit's service. A unit that
  ## names credentials but cannot load them (not a plain `.service`) is
  ## refused too. Raises `ESystemProfileInvalid`.
  var seen: seq[string]
  for d in p.secretFiles:
    let e = secretEntryPath(d.service, d.name)
    if e in seen:
      raiseSystemProfileInvalid("'" & SecretFileStanzaTag & "' " & e &
        " is declared twice")
    seen.add(e)
  for r in p.resources:
    if r.kind != srkSystemdSystemUnit or r.suCredentials.len == 0:
      continue
    let svc = credentialServiceOf(r.suName)
    if svc.len == 0:
      raiseSystemProfileInvalid("systemd.systemUnit '" & r.suName &
        "' names credentials, but only a plain `<service>.service` unit " &
        "(no template instance) can load them")
    for c in r.suCredentials:
      if secretEntryPath(svc, c) notin seen:
        raiseSystemProfileInvalid("systemd.systemUnit '" & r.suName &
          "' loads the credential '" & c & "', but the profile declares " &
          "no `" & SecretFileStanzaTag & " { service = \"" & svc &
          "\"  name = \"" & c & "\" }`")

proc managedPrefixError*(prefix: string): string =
  ## Why `prefix` cannot be a managed `/etc` prefix, or "" when it can.
  ## A prefix is written as the add-on reads it: `/etc/name/` for a
  ## subtree, `/etc/name` for that exact path (or the subtree below it).
  ## It must be canonical (`nonCanonicalPathError`): `isUnderManagedPrefix`
  ## and the class-directory check below compare text, so `/etc//ssh/` or
  ## `/etc/./systemd/system/` would match nothing they should.
  let canon = nonCanonicalPathError("managed prefix", prefix,
                                    allowTrailingSlash = true)
  if canon.len > 0:
    return canon
  if not prefix.startsWith("/etc/") and not prefix.startsWith("/usr/local/etc/"):
    return "managed prefix '" & prefix & "' is not below /etc/ or /usr/local/etc/"
  if prefix == "/etc/" or prefix == "/usr/local/etc/":
    return "managed prefix '" & prefix & "' would claim the whole directory"
  for seg in prefix.split('/'):
    if seg == "..":
      return "managed prefix '" & prefix & "' contains a '..' segment"
  for c in prefix:
    if ord(c) < 32 or c == '\\':
      return "managed prefix '" & prefix & "' contains a control character"
  let asDir = if prefix.endsWith("/"): prefix else: prefix & "/"
  for d in AddOnClassDirectories:
    if asDir == d or asDir.startsWith(d) or d.startsWith(asDir):
      return "managed prefix '" & prefix & "' overlaps " & d &
        ", which is reached through its own class and is never a " &
        "managed prefix"
  for d in UnitSearchDirectories:
    if asDir == d or asDir.startsWith(d) or d.startsWith(asDir):
      return "managed prefix '" & prefix & "' overlaps " & d &
        ", a directory systemd loads units, generators or presets from; " &
        "units are reached only through the unit and drop-in classes"
  ""

proc parseAddOnStanza*(body: string): AddOnSettings =
  ## The `addOn { managedEtcPrefixes = [...] }` stanza.
  result.declared = true
  for assignment in splitFieldAssignments(body):
    let eq = assignment.find('=')
    if eq < 0:
      raiseSystemProfileInvalid("expected 'key = value' in '" &
        AddOnStanzaTag & "', got: '" & assignment & "'")
    let key = assignment[0 ..< eq].strip()
    let rawValue = assignment[eq + 1 .. ^1].strip()
    case key
    of "managedEtcPrefixes":
      for p in parseListLiteral(rawValue):
        let err = managedPrefixError(p)
        if err.len > 0:
          raiseSystemProfileInvalid(err)
        if p notin result.managedEtcPrefixes:
          result.managedEtcPrefixes.add(p)
    of "confirmTimeout":
      var secs = 0
      try:
        secs = parseInt(rawValue.strip(chars = {'"', ' '}))
      except ValueError:
        raiseSystemProfileInvalid("'" & AddOnStanzaTag & "' confirmTimeout '" &
          rawValue & "' is not a whole number of seconds")
      if secs notin 1 .. MaxConfirmTimeoutSec:
        raiseSystemProfileInvalid("'" & AddOnStanzaTag & "' confirmTimeout " &
          $secs & " must be between 1 and " & $MaxConfirmTimeoutSec & " seconds")
      result.confirmTimeoutSec = secs
    else:
      raiseSystemProfileInvalid("'" & AddOnStanzaTag &
        "' has no field '" & key & "' (known: managedEtcPrefixes, " &
        "confirmTimeout)")

proc isUnderManagedPrefix*(path, prefix: string): bool =
  ## Does `prefix` (as declared, see `managedPrefixError`) cover `path`?
  if prefix.endsWith("/"):
    path.startsWith(prefix)
  else:
    path == prefix or path.startsWith(prefix & "/")

proc stanzaBounds(clean: string):
    seq[tuple[head, brace, close: int]] =
  ## The stanzas of comment-stripped text, as offsets: where the kind tag
  ## starts, its `{`, and the matching `}`. There is no nesting in this
  ## format. A `}` inside a double-quoted value is skipped — required for
  ## kinds whose content carries JS / shell bodies (`linux.polkitRule
  ## content = "polkit.addRule(function() { ... });"`) and for any
  ## multi-line value. Raises `ESystemProfileInvalid` on a head with no
  ## `{` or a block with no `}`.
  var pos = 0
  while pos < clean.len:
    # Skip whitespace to the next stanza head.
    while pos < clean.len and clean[pos] in {' ', '\t', '\r', '\n'}:
      inc pos
    if pos >= clean.len:
      break
    let braceIdx = clean.find('{', pos)
    if braceIdx < 0:
      let trailing = clean[pos .. ^1].strip()
      if trailing.len > 0:
        raiseSystemProfileInvalid("resource '" & trailing &
          "' must be followed by a '{' block")
      break
    var closeIdx = -1
    var i = braceIdx + 1
    var inQuote = false
    while i < clean.len:
      let c = clean[i]
      if c == '"':
        inQuote = not inQuote
      elif not inQuote and c == '}':
        closeIdx = i
        break
      inc i
    if closeIdx < 0:
      raiseSystemProfileInvalid("resource '" &
        clean[pos ..< braceIdx].strip() & "' block is not closed with '}'")
    result.add((head: pos, brace: braceIdx, close: closeIdx))
    pos = closeIdx + 1

proc systemProfileStanzaLineSpans*(text: string;
                                   lineEnding = "\n"):
    seq[tuple[startLine, endLine: int]] =
  ## The 0-based line of each stanza's kind tag and of its closing `}`, in
  ## file order, found by the SAME quote-aware walk `parseSystemProfile`
  ## uses. The text editor (`intent.stanzaSpans`) pairs these with the
  ## parsed resources, so a value holding a `{`, a `}`, a `#` or a blank
  ## line cannot make the editor and the parser disagree on where a stanza
  ## ends. Lines are counted by `lineEnding` exactly — the ending the
  ## editor split the file on — so a value holding the OTHER ending (a
  ## `\r\n` inside an LF profile, a bare `\n` inside a CRLF one) does not
  ## count as a line to one side and not the other.
  doAssert lineEnding in ["\n", "\r\n"]
  let clean = stripComments(text)
  var line = 0
  var at = 0
  proc lineOf(offset: int): int =
    while at < offset:
      if clean[at] == '\n' and
          (lineEnding == "\n" or (at > 0 and clean[at - 1] == '\r')):
        inc line
      inc at
    line
  for span in stanzaBounds(clean):
    # The `addOn` stanza is not a resource: the editor pairs spans with
    # parsed resources by ordinal, so it is left out here as it is there.
    if clean[span.head ..< span.brace].strip() in
        [AddOnStanzaTag, SecretFileStanzaTag]:
      continue
    let s = lineOf(span.head)
    let e = lineOf(span.close)
    result.add((startLine: s, endLine: e))

proc parseSystemProfile*(text: string): SystemProfile =
  ## Parse the declarative `system.nim` text into a `SystemProfile`.
  ## Raises `ESystemProfileInvalid` on any structural error or an
  ## unknown / deferred resource kind. Brace-aware: a stanza body may
  ## be on one line (`kind { k = v }`) or spread across many.
  # Strip comments globally (quote state carried across lines), then walk
  # by `{` / `}` braces. The bytes of a quoted value reach `unquote`
  # unchanged: no line splitting, so a `\r` inside a value survives too.
  let clean = stripComments(text)
  for span in stanzaBounds(clean):
    let braceIdx = span.brace
    let closeIdx = span.close
    let kindTag = clean[span.head ..< braceIdx].strip()
    if kindTag == AddOnStanzaTag:
      # The add-on's profile-wide declaration: parsed by its own routine
      # because it is not a resource and has no address.
      if result.addOn.declared:
        raiseSystemProfileInvalid("a profile may carry one '" &
          AddOnStanzaTag & "' stanza, not two")
      result.addOn = parseAddOnStanza(clean[braceIdx + 1 ..< closeIdx])
      continue
    if kindTag == SecretFileStanzaTag:
      # Not a resource either (`SecretFileDecl`): no address, no driver.
      result.secretFiles.add(parseSecretFileStanza(
        clean[braceIdx + 1 ..< closeIdx]))
      continue
    var srk: SystemResourceKind
    case kindTag
    of $srkWindowsRegistryValue: srk = srkWindowsRegistryValue
    of $srkWindowsOptionalFeature: srk = srkWindowsOptionalFeature
    of $srkWindowsCapability: srk = srkWindowsCapability
    of $srkWindowsService: srk = srkWindowsService
    of $srkWindowsScheduledTask: srk = srkWindowsScheduledTask
    of $srkWindowsVsInstaller: srk = srkWindowsVsInstaller
    of $srkWindowsFirewallRule: srk = srkWindowsFirewallRule
    of $srkWindowsAcl: srk = srkWindowsAcl
    of $srkMacosSystemDefault: srk = srkMacosSystemDefault
    of $srkSystemdSystemUnit: srk = srkSystemdSystemUnit
    of $srkLaunchdSystemDaemon: srk = srkLaunchdSystemDaemon
    of $srkFsSystemFile: srk = srkFsSystemFile
    of $srkFsSystemDirectory: srk = srkFsSystemDirectory
    of $srkEnvSystemVariable: srk = srkEnvSystemVariable
    of $srkPasswdUser: srk = srkPasswdUser
    of $srkOsTimezone: srk = srkOsTimezone
    of $srkOsHostname: srk = srkOsHostname
    of $srkLinuxSysctl: srk = srkLinuxSysctl
    of $srkLinuxUdevRule: srk = srkLinuxUdevRule
    of $srkLinuxPolkitRule: srk = srkLinuxPolkitRule
    of $srkLinuxTmpfilesRule: srk = srkLinuxTmpfilesRule
    of $srkLinuxSudoersRule: srk = srkLinuxSudoersRule
    of $srkPasswdGroup: srk = srkPasswdGroup
    of $srkLinuxNixDaemonSetting: srk = srkLinuxNixDaemonSetting
    of $srkSystemdSystemTimer: srk = srkSystemdSystemTimer
    of $srkLinuxFirewallRule: srk = srkLinuxFirewallRule
    of $srkLinuxNixosSystemModule: srk = srkLinuxNixosSystemModule
    of $srkMacosDarwinSystemModule: srk = srkMacosDarwinSystemModule
    of $srkLinuxFhsSandbox: srk = srkLinuxFhsSandbox
    of $srkLinuxDpkgDiversion: srk = srkLinuxDpkgDiversion
    of $srkSystemdUnitState: srk = srkSystemdUnitState
    of $srkLinuxAddOnTool: srk = srkLinuxAddOnTool
    of $srkSystemdSystemDropIn: srk = srkSystemdSystemDropIn
    of $srkLinuxSysusersEntry: srk = srkLinuxSysusersEntry
    else:
      raiseSystemProfileInvalid("unknown system resource kind '" &
        kindTag & "'")
    let bodyText = clean[braceIdx + 1 ..< closeIdx]
    # Collect `key = value` assignments. The RAW value (before
    # `unquote`) is kept so a `[...]` list field can be parsed with
    # `parseListLiteral`; a scalar field uses the unquoted form.
    var fields = initTable[string, string]()
    var rawFields = initTable[string, string]()
    for assignment in splitFieldAssignments(bodyText):
      let eq = assignment.find('=')
      if eq < 0:
        raiseSystemProfileInvalid("expected 'key = value' in resource '" &
          kindTag & "', got: '" & assignment & "'")
      let key = assignment[0 ..< eq].strip()
      let rawValue = assignment[eq + 1 .. ^1].strip()
      rawFields[key] = rawValue
      fields[key] = unquote(rawValue)
    # Build the typed resource.
    proc need(k: string): string =
      if k notin fields:
        raiseSystemProfileInvalid("resource '" & kindTag &
          "' is missing required field '" & k & "'")
      fields[k]
    var res: SystemResource
    case srk
    of srkWindowsRegistryValue:
      let key = need("key")
      if not isHklmKey(key):
        raiseSystemProfileInvalid("windows.registryValue requires an " &
          "HKLM key (scope=system); got '" & key &
          "' — HKCU values are home-scope resources")
      let valueKindTag =
        if "kind" in fields: fields["kind"] else: "string"
      if not isKnownSystemRegistryValueKind(valueKindTag):
        raiseSystemProfileInvalid("windows.registryValue 'kind' '" &
          valueKindTag & "' is not a known typed value kind")
      res = SystemResource(kind: srkWindowsRegistryValue,
        regKey: key,
        regName: (if "name" in fields: fields["name"] else: ""),
        regValueKind: systemRegistryValueKindFromString(valueKindTag),
        regValueLiteral: (if "value" in fields: fields["value"] else: ""))
    of srkWindowsOptionalFeature:
      res = SystemResource(kind: srkWindowsOptionalFeature,
        featureName: need("name"),
        featureEnabled:
          if "enabled" in fields: parseBoolField("enabled",
            fields["enabled"]) else: true)
    of srkWindowsCapability:
      res = SystemResource(kind: srkWindowsCapability,
        capabilityName: need("name"),
        capabilityInstalled:
          if "installed" in fields: parseBoolField("installed",
            fields["installed"]) else: true)
    of srkWindowsService:
      let st =
        if "startType" in fields: fields["startType"] else: "Automatic"
      if st notin ["Automatic", "Manual", "Disabled"]:
        raiseSystemProfileInvalid("windows.service startType '" & st &
          "' is not one of Automatic / Manual / Disabled")
      let stateStr =
        if "state" in fields: fields["state"].toLowerAscii() else: "running"
      if stateStr notin ["running", "stopped"]:
        raiseSystemProfileInvalid("windows.service state '" & stateStr &
          "' is not one of Running / Stopped")
      # Windows-System-Resources Phase B: the four new optional fields.
      # Each is "default = leave unmanaged" — the parser accepts a
      # stanza that omits them (the back-compat case) and the SystemResource
      # carries the absent value as empty string / 0 / empty seq.
      let svcName = need("name")
      let svcDisplay =
        if "displayName" in fields: fields["displayName"] else: ""
      let svcBinPath =
        if "binPath" in fields: fields["binPath"] else: ""
      var svcRecovery: seq[WindowsServiceRecoverySpec] = @[]
      if "recoveryActions" in rawFields:
        let tokens = parseListLiteral(rawFields["recoveryActions"])
        if tokens.len > 3:
          raiseSystemProfileInvalid("windows.service '" & svcName &
            "' recoveryActions has " & $tokens.len &
            " entries — sc.exe failure consumes at most 3 slots")
        for tok in tokens:
          let sep = tok.find(':')
          if sep <= 0 or sep == tok.len - 1:
            raiseSystemProfileInvalid("windows.service '" & svcName &
              "' recoveryActions entry '" & tok &
              "' is malformed (expected '<action>:<delayMs>')")
          let actionTok = tok[0 ..< sep]
          let delayStr = tok[sep + 1 .. ^1]
          if not isKnownWindowsServiceRecoveryActionToken(actionTok):
            raiseSystemProfileInvalid("windows.service '" & svcName &
              "' recoveryActions entry '" & tok &
              "' names an unknown action '" & actionTok &
              "' (expected restart / runcommand / reboot / none)")
          var delayMs: int
          try:
            delayMs = parseInt(delayStr)
          except ValueError:
            raiseSystemProfileInvalid("windows.service '" & svcName &
              "' recoveryActions entry '" & tok &
              "' has a non-integer delay '" & delayStr & "'")
          if delayMs < 0:
            raiseSystemProfileInvalid("windows.service '" & svcName &
              "' recoveryActions entry '" & tok &
              "' has a negative delay (must be >= 0)")
          svcRecovery.add(WindowsServiceRecoverySpec(
            action: windowsServiceRecoveryActionFromToken(actionTok),
            delayMs: delayMs))
      var svcRecoveryReset = 0
      if "recoveryResetSeconds" in fields:
        let raw = fields["recoveryResetSeconds"].strip()
        try:
          svcRecoveryReset = parseInt(raw)
        except ValueError:
          raiseSystemProfileInvalid("windows.service '" & svcName &
            "' recoveryResetSeconds '" & raw & "' is not an integer")
        if svcRecoveryReset < 0:
          raiseSystemProfileInvalid("windows.service '" & svcName &
            "' recoveryResetSeconds '" & raw &
            "' is negative (must be >= 0)")
      res = SystemResource(kind: srkWindowsService,
        serviceName: svcName,
        serviceStartType: st,
        serviceRunning: stateStr == "running",
        serviceDisplayName: svcDisplay,
        serviceBinPath: svcBinPath,
        serviceRecoveryActions: svcRecovery,
        serviceRecoveryResetSeconds: svcRecoveryReset)
    of srkWindowsScheduledTask:
      # Windows-System-Resources Phase C: every layer in the
      # closed-set defence chain (template / text parser / adapter /
      # broker validator) re-checks the same shape so a bypass through
      # any one path still fails closed. The text parser is layer 2.
      let wstTaskName = need("taskName")
      if wstTaskName.len == 0:
        raiseSystemProfileInvalid("windows.scheduledTask requires a " &
          "non-empty taskName")
      let wstExecutable = need("executable")
      if wstExecutable.len == 0:
        raiseSystemProfileInvalid("windows.scheduledTask '" & wstTaskName &
          "' requires a non-empty executable")
      let wstArguments =
        if "arguments" in rawFields: parseListLiteral(rawFields["arguments"])
        else: @[]
      let wstWorkingDirectory =
        if "workingDirectory" in fields: fields["workingDirectory"] else: ""
      let wstRunAsUser =
        if "runAsUser" in fields: fields["runAsUser"] else: "SYSTEM"
      let wstRunWithHighest =
        if "runWithHighestPrivileges" in fields:
          parseBoolField("runWithHighestPrivileges",
            fields["runWithHighestPrivileges"])
        else: wstRunAsUser == "SYSTEM"
      let wstEnabled =
        if "enabled" in fields: parseBoolField("enabled",
          fields["enabled"]) else: true
      # `schedule` arrives as a single-element list literal under the
      # canonical wire-token convention (`<kind>:<payload>`). A missing
      # field is a hard error — the spec requires the trigger.
      if "schedule" notin rawFields:
        raiseSystemProfileInvalid("windows.scheduledTask '" & wstTaskName &
          "' is missing required field 'schedule'")
      let scheduleTokens = parseListLiteral(rawFields["schedule"])
      if scheduleTokens.len != 1:
        raiseSystemProfileInvalid("windows.scheduledTask '" & wstTaskName &
          "' schedule must be a single-element list (got " &
          $scheduleTokens.len & " entries)")
      var wstSchedule: ScheduledTaskScheduleSpec
      try:
        wstSchedule = decodeScheduledTaskScheduleToken(scheduleTokens[0])
      except ValueError as e:
        raiseSystemProfileInvalid("windows.scheduledTask '" & wstTaskName &
          "' schedule: " & e.msg)
      res = SystemResource(kind: srkWindowsScheduledTask,
        wstTaskName: wstTaskName,
        wstExecutable: wstExecutable,
        wstArguments: wstArguments,
        wstWorkingDirectory: wstWorkingDirectory,
        wstRunAsUser: wstRunAsUser,
        wstRunWithHighestPrivileges: wstRunWithHighest,
        wstSchedule: wstSchedule,
        wstEnabled: wstEnabled)
    of srkWindowsVsInstaller:
      let workloads =
        if "workloads" in rawFields: parseListLiteral(rawFields["workloads"])
        else: @[]
      let components =
        if "components" in rawFields: parseListLiteral(rawFields["components"])
        else: @[]
      res = SystemResource(kind: srkWindowsVsInstaller,
        vsEdition: need("edition"),
        vsChannel: (if "channel" in fields: fields["channel"]
                    else: "Release"),
        vsInstallPath: (if "installPath" in fields: fields["installPath"]
                        else: ""),
        vsWorkloads: workloads,
        vsComponents: components,
        vsStrict: (if "strict" in fields: parseBoolField("strict",
          fields["strict"]) else: false))
    of srkWindowsFirewallRule:
      let fname = need("name")
      let displayName =
        if "displayName" in fields: fields["displayName"] else: ""
      let protocol = need("protocol")
      if protocol notin FirewallProtocols:
        raiseSystemProfileInvalid("windows.firewallRule protocol '" &
          protocol & "' is not one of " & FirewallProtocols.join(" / "))
      let direction = need("direction")
      if direction notin FirewallDirections:
        raiseSystemProfileInvalid("windows.firewallRule direction '" &
          direction & "' is not one of " &
          FirewallDirections.join(" / "))
      let action = need("action")
      if action notin FirewallActions:
        raiseSystemProfileInvalid("windows.firewallRule action '" &
          action & "' is not one of " & FirewallActions.join(" / "))
      let localPort =
        if "localPort" in fields: fields["localPort"] else: ""
      if not isSafeFirewallIdentifier(fname):
        raiseSystemProfileInvalid("windows.firewallRule name '" & fname &
          "' contains characters outside the firewall-identifier " &
          "charset (letters, digits, '.', '-', '_', space)")
      if displayName.len > 0 and not isSafeFirewallDisplayName(displayName):
        raiseSystemProfileInvalid("windows.firewallRule displayName '" &
          displayName & "' contains a single-quote or control character")
      if localPort.len > 0 and not isSafeFirewallPort(localPort):
        raiseSystemProfileInvalid("windows.firewallRule localPort '" &
          localPort & "' is not a port number, port range, comma list, " &
          "or 'Any'")
      res = SystemResource(kind: srkWindowsFirewallRule,
        fwName: fname,
        fwDisplayName: displayName,
        fwProtocol: protocol,
        fwDirection: direction,
        fwAction: action,
        fwLocalPort: localPort,
        fwEnabled:
          if "enabled" in fields: parseBoolField("enabled",
            fields["enabled"]) else: true)
    of srkWindowsAcl:
      let aclPath = need("path")
      if not isSafeAclPath(aclPath):
        raiseSystemProfileInvalid("windows.acl path '" & aclPath &
          "' contains characters outside the safe-path charset " &
          "(no '..' segment, no quote / shell metacharacter / " &
          "control character)")
      let aclOwner =
        if "owner" in fields: fields["owner"] else: ""
      if aclOwner.len > 0 and not isSafeAclPrincipal(aclOwner):
        raiseSystemProfileInvalid("windows.acl owner '" & aclOwner &
          "' contains characters outside the principal charset " &
          "(letters, digits, '\\', ' ', '.', '-', '_', '@')")
      let inheritanceMode =
        if "inheritanceMode" in fields: fields["inheritanceMode"]
        else: ""
      if inheritanceMode.len > 0 and
         inheritanceMode notin AclInheritanceModes:
        raiseSystemProfileInvalid("windows.acl inheritanceMode '" &
          inheritanceMode & "' is not one of " &
          AclInheritanceModes.join(" / "))
      let entries =
        if "accessControlEntries" in rawFields:
          parseListLiteral(rawFields["accessControlEntries"])
        else: @[]
      if entries.len == 0:
        raiseSystemProfileInvalid("windows.acl '" & aclPath &
          "' requires a non-empty accessControlEntries list")
      for e in entries:
        if not isSafeAclEntry(e):
          raiseSystemProfileInvalid("windows.acl entry '" & e &
            "' is not a safe `<principal>:<perms>` ACE spec " &
            "(principal must be in the NTAccount / SID charset; " &
            "perms must use only icacls permission codes, '(', " &
            "')', ',', ' ')")
      res = SystemResource(kind: srkWindowsAcl,
        aclPath: aclPath,
        aclOwner: aclOwner,
        aclEntries: entries,
        aclInheritanceMode: inheritanceMode)
    of srkMacosSystemDefault:
      res = SystemResource(kind: srkMacosSystemDefault,
        sdDomain: need("domain"),
        sdKey: need("key"),
        sdValueType: (if "type" in fields: fields["type"] else: "-string"),
        sdValueLiteral: (if "value" in fields: fields["value"] else: ""),
        sdRestartTarget: (if "restartTarget" in fields:
          fields["restartTarget"] else: ""))
    of srkSystemdSystemUnit:
      # A name systemd accepts, exactly as written: the unit file's path is
      # derived from its text, so `" cron.service"` would be a different
      # file from the one every observer of `cron.service` looks at.
      let unitNameErr = systemdUnitNameError("systemd.systemUnit name",
                                             need("name"))
      if unitNameErr.len > 0:
        raiseSystemProfileInvalid(unitNameErr)
      res = SystemResource(kind: srkSystemdSystemUnit,
        suName: need("name"),
        suContent: need("content"),
        suEnabled:
          if "enabled" in fields: parseBoolField("enabled",
            fields["enabled"]) else: true,
        suAptClosureLock:
          if "aptClosureLock" in fields: fields["aptClosureLock"] else: "",
        suRestartHeld:
          if "restartIfChanged" in fields:
            not parseBoolField("restartIfChanged", fields["restartIfChanged"])
          else: false,
        suCollision: parseCollisionField(kindTag,
          (if "collision" in fields: fields["collision"] else: ""),
          UnitCollisionOptIns),
        suDropInName:
          if "dropInName" in fields: fields["dropInName"] else: "",
        suStopHeld:
          if "stopOnRemoval" in fields:
            not parseBoolField("stopOnRemoval", fields["stopOnRemoval"])
          else: false,
        suReloadIfChanged:
          if "reloadIfChanged" in fields:
            parseBoolField("reloadIfChanged", fields["reloadIfChanged"])
          else: false,
        suExclusive:
          if "exclusive" in fields:
            parseBoolField("exclusive", fields["exclusive"])
          else: false,
        suHealthCheck:
          if "healthCheck" in fields: fields["healthCheck"] else: "",
        suCredentials:
          if "credentials" in rawFields: parseListLiteral(rawFields["credentials"])
          else: @[])
      if res.suHealthCheck.len > 0:
        discard parseHealthCheck(res.suHealthCheck)
      if res.suDropInName.len > 0 and res.suCollision != "dropIn":
        raiseSystemProfileInvalid("systemd.systemUnit '" & res.suName &
          "' sets dropInName without `collision = \"dropIn\"`")
      if res.suDropInName.len > 0 and not isSafeDropInName(res.suDropInName):
        raiseSystemProfileInvalid("systemd.systemUnit '" & res.suName &
          "' dropInName '" & res.suDropInName & "' must be one path " &
          "segment of letters, digits, '.', '-' or '_'")
      # Refuse an unbindable unit or a malformed lock at parse time, not
      # at apply time on the host.
      discard renderedSystemUnitContent(res)
    of srkLaunchdSystemDaemon:
      let programArgs =
        if "programArgs" in rawFields:
          parseListLiteral(rawFields["programArgs"])
        else: @[]
      if programArgs.len == 0:
        raiseSystemProfileInvalid("launchd.systemDaemon '" &
          (if "label" in fields: fields["label"] else: "?") &
          "' requires a non-empty programArgs list")
      res = SystemResource(kind: srkLaunchdSystemDaemon,
        sdaLabel: need("label"),
        sdaProgramArgs: programArgs,
        sdaRunAtLoad:
          if "runAtLoad" in fields: parseBoolField("runAtLoad",
            fields["runAtLoad"]) else: true)
    of srkFsSystemFile:
      let sfPath = need("path")
      # A POSIX path must be canonical: the drivers' allowlist and the
      # add-on's scope and ownership checks compare its text, and a
      # `//` or `.` segment would let it name a file those checks never
      # see (`nonCanonicalPathError`). A Windows `${PROGRAMDATA}` path is
      # not POSIX-absolute and is checked by its driver.
      if sfPath.startsWith("/"):
        let canon = nonCanonicalPathError("fs.systemFile path", sfPath)
        if canon.len > 0:
          raiseSystemProfileInvalid(canon)
      let sfContent =
        if "content" in fields: fields["content"] else: ""
      let sfSourceUrl =
        if "sourceUrl" in fields: fields["sourceUrl"] else: ""
      let sfSha256 =
        if "sha256" in fields: fields["sha256"] else: ""
      let sfSourceLocal =
        if "sourceLocal" in fields: fields["sourceLocal"] else: ""
      # Mutual-exclusion: at most one of `content` / `sourceUrl` /
      # `sourceLocal` may be non-empty. Defence-in-depth — the template
      # already raises at compile time, but a hand-authored / generated
      # profile that bypasses the template MUST also fail closed here.
      let nonEmptySources = (if sfContent.len > 0: 1 else: 0) +
                            (if sfSourceUrl.len > 0: 1 else: 0) +
                            (if sfSourceLocal.len > 0: 1 else: 0)
      if nonEmptySources > 1:
        raiseSystemProfileInvalid("fs.systemFile '" & sfPath &
          "' declares more than one content source — at most one of " &
          "`content`, `sourceUrl`, `sourceLocal` may be non-empty")
      # `sourceUrl` MUST be paired with `sha256` so a fetch always has
      # something to verify against. A bare `sha256` without a URL is
      # equally meaningless — both directions fail closed.
      if sfSourceUrl.len > 0 and sfSha256.len == 0:
        raiseSystemProfileInvalid("fs.systemFile '" & sfPath &
          "' sets `sourceUrl` but no `sha256` — the URL fetch requires " &
          "a lowercase 64-char BLAKE3 hex digest to verify against")
      if sfSha256.len > 0 and sfSourceUrl.len == 0:
        raiseSystemProfileInvalid("fs.systemFile '" & sfPath &
          "' sets `sha256` but no `sourceUrl` — the digest is only " &
          "meaningful when paired with a URL fetch")
      res = SystemResource(kind: srkFsSystemFile,
        sfPath: sfPath,
        sfContent: sfContent,
        sfSourceUrl: sfSourceUrl,
        sfSha256: sfSha256,
        sfSourceLocal: sfSourceLocal,
        sfCollision: parseCollisionField(kindTag,
          (if "collision" in fields: fields["collision"] else: ""),
          FileCollisionOptIns))
    of srkFsSystemDirectory:
      let dirPath = need("path")
      # ACL is optional: a stanza without aclEntries leaves ACL
      # management to the host / parent inheritance. When any of the
      # acl* fields appears the entries list must be non-empty.
      let aclEntries =
        if "aclEntries" in rawFields:
          parseListLiteral(rawFields["aclEntries"])
        else: @[]
      let aclOwner =
        if "aclOwner" in fields: fields["aclOwner"] else: ""
      let aclInheritance =
        if "aclInheritance" in fields: fields["aclInheritance"] else: ""
      let aclPresent = aclEntries.len > 0 or aclOwner.len > 0 or
                       aclInheritance.len > 0
      if aclPresent and aclEntries.len == 0:
        raiseSystemProfileInvalid("fs.systemDirectory '" & dirPath &
          "' has aclOwner / aclInheritance but no aclEntries — " &
          "set at least one aclEntries spec or remove the other " &
          "acl* fields to leave the ACL unmanaged")
      for e in aclEntries:
        if not isSafeAclEntry(e):
          raiseSystemProfileInvalid("fs.systemDirectory aclEntry '" & e &
            "' is not a safe `<principal>:<perms>` ACE spec " &
            "(principal must be in the NTAccount / SID charset; " &
            "perms must use only icacls permission codes, '(', " &
            "')', ',', ' ')")
      if aclOwner.len > 0 and not isSafeAclPrincipal(aclOwner):
        raiseSystemProfileInvalid("fs.systemDirectory aclOwner '" &
          aclOwner & "' contains characters outside the principal " &
          "charset (letters, digits, '\\', ' ', '.', '-', '_', '@')")
      if aclInheritance.len > 0 and
         aclInheritance notin DirectoryAclInheritanceModes:
        raiseSystemProfileInvalid("fs.systemDirectory aclInheritance '" &
          aclInheritance & "' is not one of " &
          DirectoryAclInheritanceModes.join(" / "))
      res = SystemResource(kind: srkFsSystemDirectory,
        dirPath: dirPath,
        dirAclPresent: aclPresent,
        dirAclOwner: aclOwner,
        dirAclEntries: aclEntries,
        dirAclInheritance: aclInheritance)
    of srkEnvSystemVariable:
      let contribution =
        if "contribute" in rawFields:
          parseListLiteral(rawFields["contribute"])
        else: @[]
      res = SystemResource(kind: srkEnvSystemVariable,
        evName: need("name"),
        evContribution: contribution,
        evIsPathList:
          if "isPathList" in fields: parseBoolField("isPathList",
            fields["isPathList"]) else: false)
    of srkPasswdUser:
      let groups =
        if "groups" in rawFields: parseListLiteral(rawFields["groups"])
        else: @[]
      res = SystemResource(kind: srkPasswdUser,
        puName: need("name"),
        puHome: (if "home" in fields: fields["home"] else: ""),
        puShell: (if "shell" in fields: fields["shell"] else: ""),
        puGroups: groups)
    of srkOsTimezone:
      let iana = need("tz")
      if not isSafeIanaTimezone(iana):
        raiseSystemProfileInvalid("os.timezone tz '" & iana &
          "' contains characters outside the IANA charset (letters, " &
          "digits, '/', '_', '-', '+', '.')")
      if not isMappedIanaTimezone(iana):
        raiseSystemProfileInvalid("os.timezone tz '" & iana &
          "' is not in the embedded IANA -> Windows mapping table; " &
          "add it to IanaToWindowsTzTable in os_system_parse.nim or " &
          "use a mapped IANA name")
      res = SystemResource(kind: srkOsTimezone, tzIana: iana)
    of srkOsHostname:
      let h = need("hostname")
      if not isSafeHostname(h):
        raiseSystemProfileInvalid("os.hostname '" & h &
          "' is not a valid RFC 1123 hostname (letters, digits, '-' " &
          "only; 1-63 octets; no leading/trailing '-')")
      res = SystemResource(kind: srkOsHostname, hostnameName: h)
    of srkLinuxSysctl:
      let k = need("key")
      let v = need("value")
      if not isSafeSysctlKey(k):
        raiseSystemProfileInvalid("linux.sysctl key '" & k &
          "' contains characters outside the sysctl-key charset " &
          "(letters, digits, '.', '-', '_', '/')")
      if not isSafeSysctlValue(v):
        raiseSystemProfileInvalid("linux.sysctl value for key '" & k &
          "' contains a newline — a sysctl drop-in file is one " &
          "key=value line, so a newline in the value would corrupt the file")
      let filename =
        if "filename" in fields: fields["filename"] else: ""
      if filename.len > 0:
        if not isSafeDropInBasename(filename):
          raiseSystemProfileInvalid("linux.sysctl filename '" & filename &
            "' is not a safe single-segment basename (letters, digits, " &
            "'.', '-', '_'; no '/', '..', or shell metacharacter)")
        if not filename.endsWith(".conf"):
          raiseSystemProfileInvalid("linux.sysctl filename '" & filename &
            "' must end with '.conf' (sysctl.d convention)")
      res = SystemResource(kind: srkLinuxSysctl,
        sysctlKey: k, sysctlValue: v, sysctlFilename: filename)
    of srkLinuxUdevRule:
      let n = need("name")
      let c = need("content")
      if not isSafeDropInBasename(n):
        raiseSystemProfileInvalid("linux.udevRule name '" & n &
          "' is not a safe single-segment basename (letters, digits, " &
          "'.', '-', '_'; no '/', '..', or shell metacharacter)")
      if not n.endsWith(".rules"):
        raiseSystemProfileInvalid("linux.udevRule name '" & n &
          "' must end with '.rules' (udev convention)")
      res = SystemResource(kind: srkLinuxUdevRule,
        udevName: n, udevContent: c)
    of srkLinuxPolkitRule:
      let n = need("name")
      let c = need("content")
      if not isSafeDropInBasename(n):
        raiseSystemProfileInvalid("linux.polkitRule name '" & n &
          "' is not a safe single-segment basename (letters, digits, " &
          "'.', '-', '_'; no '/', '..', or shell metacharacter)")
      if not n.endsWith(".rules"):
        raiseSystemProfileInvalid("linux.polkitRule name '" & n &
          "' must end with '.rules' (polkit convention)")
      res = SystemResource(kind: srkLinuxPolkitRule,
        polkitName: n, polkitContent: c)
    of srkLinuxTmpfilesRule:
      let n = need("name")
      let c = need("content")
      if not isSafeDropInBasename(n):
        raiseSystemProfileInvalid("linux.tmpfilesRule name '" & n &
          "' is not a safe single-segment basename (letters, digits, " &
          "'.', '-', '_'; no '/', '..', or shell metacharacter)")
      if not n.endsWith(".conf"):
        raiseSystemProfileInvalid("linux.tmpfilesRule name '" & n &
          "' must end with '.conf' (tmpfiles.d convention)")
      let applyNow =
        if "applyNow" in fields: parseBoolField("applyNow",
          fields["applyNow"]) else: true
      res = SystemResource(kind: srkLinuxTmpfilesRule,
        tmpfilesName: n, tmpfilesContent: c,
        tmpfilesApplyNow: applyNow)
    of srkLinuxSudoersRule:
      let n = need("name")
      let c = need("content")
      if not isSafeDropInBasename(n):
        raiseSystemProfileInvalid("linux.sudoersRule name '" & n &
          "' is not a safe single-segment basename (letters, digits, " &
          "'.', '-', '_'; no '/', '..', or shell metacharacter)")
      if n.contains('.'):
        raiseSystemProfileInvalid("linux.sudoersRule name '" & n &
          "' must not contain '.' — sudo silently ignores sudoers.d " &
          "files with a '.' in the basename")
      res = SystemResource(kind: srkLinuxSudoersRule,
        sudoersName: n, sudoersContent: c)
    of srkPasswdGroup:
      let n = need("name")
      if not isSafePosixUserOrGroupName(n):
        raiseSystemProfileInvalid("passwd.group name '" & n &
          "' is not a valid POSIX group name (letters, digits, '.', " &
          "'-', '_'; no leading '-')")
      let gidStr =
        if "gid" in fields: fields["gid"].strip() else: ""
      if not isSafeGid(gidStr):
        raiseSystemProfileInvalid("passwd.group gid '" & gidStr &
          "' is not a non-negative decimal integer")
      let members =
        if "members" in rawFields: parseListLiteral(rawFields["members"])
        else: @[]
      for m in members:
        if not isSafePosixUserOrGroupName(m):
          raiseSystemProfileInvalid("passwd.group member '" & m &
            "' is not a valid POSIX user name (letters, digits, '.', " &
            "'-', '_'; no leading '-')")
      res = SystemResource(kind: srkPasswdGroup,
        pgName: n, pgGid: gidStr, pgMembers: members)
    of srkLinuxNixDaemonSetting:
      let k = need("key")
      let v = need("value")
      if not isSafeNixDaemonKey(k):
        raiseSystemProfileInvalid("linux.nixDaemonSetting key '" & k &
          "' contains characters outside the Nix-key charset " &
          "(letters, digits, '-', '_')")
      if not isSafeNixDaemonValue(v):
        raiseSystemProfileInvalid("linux.nixDaemonSetting value for key '" &
          k & "' contains a newline — a nix.conf drop-in entry is one " &
          "key=value line, so a newline in the value would corrupt the file")
      let filename =
        if "filename" in fields: fields["filename"] else: ""
      if filename.len > 0:
        if not isSafeDropInBasename(filename):
          raiseSystemProfileInvalid("linux.nixDaemonSetting filename '" &
            filename & "' is not a safe single-segment basename " &
            "(letters, digits, '.', '-', '_'; no '/', '..', or shell " &
            "metacharacter)")
        if not filename.endsWith(".conf"):
          raiseSystemProfileInvalid("linux.nixDaemonSetting filename '" &
            filename & "' must end with '.conf' (nix.conf.d convention)")
      res = SystemResource(kind: srkLinuxNixDaemonSetting,
        nixKey: k, nixValue: v, nixFilename: filename)
    of srkSystemdSystemTimer:
      let n = need("name")
      let c = need("content")
      if not isSafeUnitName(n):
        raiseSystemProfileInvalid("systemd.systemTimer name '" & n &
          "' is not a safe single-segment unit file name")
      if not n.endsWith(".timer"):
        raiseSystemProfileInvalid("systemd.systemTimer name '" & n &
          "' must end with '.timer' (systemd timer convention)")
      let stateStr =
        if "state" in fields: fields["state"].toLowerAscii() else: "running"
      if stateStr notin ["running", "stopped"]:
        raiseSystemProfileInvalid("systemd.systemTimer state '" & stateStr &
          "' is not one of Running / Stopped")
      res = SystemResource(kind: srkSystemdSystemTimer,
        stName: n, stContent: c,
        stEnabled:
          if "enabled" in fields: parseBoolField("enabled",
            fields["enabled"]) else: true,
        stRunning: stateStr == "running")
    of srkLinuxFirewallRule:
      let chain = need("chain")
      let lname = need("name")
      let protocol = need("protocol")
      let action = need("action")
      if not isSafeNftChain(chain):
        raiseSystemProfileInvalid("linux.firewallRule chain '" & chain &
          "' is not a `<family> <table> <chain>` triple in the " &
          "conservative nftables identifier charset")
      if not isSafeNftRuleName(lname):
        raiseSystemProfileInvalid("linux.firewallRule name '" & lname &
          "' contains characters outside the rule-identifier charset " &
          "(letters, digits, '.', '-', '_')")
      if protocol notin LinuxFirewallProtocols:
        raiseSystemProfileInvalid("linux.firewallRule protocol '" &
          protocol & "' is not one of " &
          LinuxFirewallProtocols.join(" / "))
      if action notin LinuxFirewallActions:
        raiseSystemProfileInvalid("linux.firewallRule action '" &
          action & "' is not one of " &
          LinuxFirewallActions.join(" / "))
      let direction =
        if "direction" in fields: fields["direction"] else: "inbound"
      if direction notin LinuxFirewallDirections:
        raiseSystemProfileInvalid("linux.firewallRule direction '" &
          direction & "' is not one of " &
          LinuxFirewallDirections.join(" / "))
      let localPort =
        if "localPort" in fields: fields["localPort"] else: ""
      if localPort.len > 0 and not isSafeNftPort(localPort):
        raiseSystemProfileInvalid("linux.firewallRule localPort '" &
          localPort & "' is not a port number, port range, comma " &
          "list, or 'any'")
      # tcp / udp need a port; icmp / icmpv6 ignore it.
      if protocol in ["tcp", "udp"] and
         (localPort.strip().len == 0 or localPort.strip() == "any"):
        raiseSystemProfileInvalid("linux.firewallRule for protocol '" &
          protocol & "' requires a non-empty localPort (port number, " &
          "range, or comma list)")
      res = SystemResource(kind: srkLinuxFirewallRule,
        lfwChain: chain, lfwName: lname,
        lfwProtocol: protocol, lfwDirection: direction,
        lfwLocalPort: localPort, lfwAction: action)
    of srkLinuxNixosSystemModule:
      let n = need("name")
      let c = need("content")
      if not isSafeDropInBasename(n):
        raiseSystemProfileInvalid("linux.nixosSystemModule name '" & n &
          "' is not a safe single-segment basename (letters, digits, " &
          "'.', '-', '_'; no '/', '..', or shell metacharacter)")
      if not n.endsWith(".nix"):
        raiseSystemProfileInvalid("linux.nixosSystemModule name '" & n &
          "' must end with '.nix' (Nix module convention)")
      res = SystemResource(kind: srkLinuxNixosSystemModule,
        nixosModuleName: n, nixosModuleContent: c)
    of srkMacosDarwinSystemModule:
      let n = need("name")
      let c = need("content")
      if not isSafeDropInBasename(n):
        raiseSystemProfileInvalid("macos.darwinSystemModule name '" & n &
          "' is not a safe single-segment basename (letters, digits, " &
          "'.', '-', '_'; no '/', '..', or shell metacharacter)")
      if not n.endsWith(".nix"):
        raiseSystemProfileInvalid("macos.darwinSystemModule name '" & n &
          "' must end with '.nix' (Nix module convention)")
      res = SystemResource(kind: srkMacosDarwinSystemModule,
        darwinModuleName: n, darwinModuleContent: c)
    of srkSystemdUnitState:
      let stateStr =
        if "state" in fields: fields["state"].toLowerAscii() else: "running"
      if stateStr notin ["running", "stopped"]:
        raiseSystemProfileInvalid("systemd.unitState state '" & stateStr &
          "' is not one of Running / Stopped")
      res = SystemResource(kind: srkSystemdUnitState,
        usName: need("name"),
        usEnabled:
          if "enabled" in fields: parseBoolField("enabled",
            fields["enabled"]) else: true,
        usRunning: stateStr == "running")
      checkUnitStateResource(res)
    of srkLinuxAddOnTool:
      let command = need("command")
      res = SystemResource(kind: srkLinuxAddOnTool,
        atCommand: command,
        atAptClosureLock: need("aptClosureLock"),
        atProgram:
          if "program" in fields: fields["program"]
          else: "/usr/bin/" & command)
      checkAddOnToolResource(res)
    of srkSystemdSystemDropIn:
      res = SystemResource(kind: srkSystemdSystemDropIn,
        diUnit: need("unit"),
        diName: (if "name" in fields: fields["name"] else: "addon"),
        diContent: need("content"),
        diRestartHeld:
          if "restartIfChanged" in fields:
            not parseBoolField("restartIfChanged", fields["restartIfChanged"])
          else: false)
      checkDropInResource(res)
    of srkLinuxSysusersEntry:
      res = SystemResource(kind: srkLinuxSysusersEntry,
        seName: need("name"),
        seKind: (if "kind" in fields: fields["kind"] else: "user"),
        seId: (if "id" in fields: fields["id"] else: ""),
        seDescription:
          (if "description" in fields: fields["description"] else: ""),
        seHome: (if "home" in fields: fields["home"] else: ""),
        seShell: (if "shell" in fields: fields["shell"] else: ""))
      checkSysusersEntryResource(res)
    of srkLinuxFhsSandbox:
      let binPath = need("binPath")
      if not isPosixAbsolutePath(binPath):
        raiseSystemProfileInvalid("linux.fhsSandbox binPath '" & binPath &
          "' is not an absolute path (must start with '/')")
      if containsNul(binPath):
        raiseSystemProfileInvalid("linux.fhsSandbox binPath contains a " &
          "NUL byte (refused — execve would reject the argv element)")
      let fhsTrees =
        if "fhsTrees" in rawFields: parseListLiteral(rawFields["fhsTrees"])
        else: @[]
      if fhsTrees.len == 0:
        raiseSystemProfileInvalid("linux.fhsSandbox '" & binPath &
          "' requires a non-empty fhsTrees list (M1 uses the first " &
          "entry; M2 will compose multiple)")
      for root in fhsTrees:
        if not isPosixAbsolutePath(root):
          raiseSystemProfileInvalid("linux.fhsSandbox fhsTrees entry '" &
            root & "' is not an absolute path (must start with '/')")
        if containsNul(root):
          raiseSystemProfileInvalid("linux.fhsSandbox fhsTrees entry " &
            "contains a NUL byte (refused — execve would reject the " &
            "argv element)")
      let argv =
        if "argv" in rawFields: parseListLiteral(rawFields["argv"])
        else: @[]
      for a in argv:
        if containsNul(a):
          raiseSystemProfileInvalid("linux.fhsSandbox argv entry " &
            "contains a NUL byte (refused — execve would reject the " &
            "argv element)")
      res = SystemResource(kind: srkLinuxFhsSandbox,
        fsbBinPath: binPath, fsbFhsTreeRoots: fhsTrees, fsbArgv: argv)
    of srkLinuxDpkgDiversion:
      # The diversion's own validation (absolute, below /etc/ or
      # /usr/local/etc/, no '..') is the operation's, so a hand-written
      # profile and the broker refuse the same paths.
      let p = need("path")
      let op = PrivilegedOperation(kind: pokLinuxDpkgDiversion,
        address: "dpkgDiversion:" & p, ddPath: p)
      let err = operationValidationError(op)
      if err.len > 0:
        raiseSystemProfileInvalid(err)
      res = SystemResource(kind: srkLinuxDpkgDiversion, ddPath: p)
    res.address =
      if "address" in fields and fields["address"].len > 0: fields["address"]
      else: realWorldIdentity(res)
    # M82 Phase B: optional `depends_on = ["kind:name", ...]` attribute.
    # Absent / empty is the common case (most resources have no
    # declared dependencies — they are independent ops). When present,
    # the parser validates each entry's shape; the planner later
    # resolves each `(kind, name)` to a node in the dependency graph
    # and adds an explicit edge.
    if "depends_on" in rawFields:
      res.dependsOn = parseDependsOn(kindTag, rawFields["depends_on"])
    result.resources.add(res)
  checkUnitStateConflicts(result.resources)
  checkPasswdPrimaryGroups(result.resources)
  checkSecretDeclarations(result)

# ---------------------------------------------------------------------------
# SystemResource -> typed PrivilegedOperation. A `destroy` flag flips
# the resource into its rollback direction (delete the value /
# disable the feature / uninstall the capability). `windows.service`
# has no destroy direction beyond the recorded pre-write state, so a
# destroy is modelled by the rollback engine, not here.
# ---------------------------------------------------------------------------

proc toPrivilegedOperation*(r: SystemResource;
                            destroy = false): PrivilegedOperation =
  ## Convert a declared resource into the typed `PrivilegedOperation`
  ## the M81 broker dispatches. `destroy = true` selects the rollback
  ## direction.
  case r.kind
  of srkWindowsRegistryValue:
    PrivilegedOperation(kind: pokWindowsRegistryValue, address: r.address,
      hklmSubkey: stripHklmPrefix(r.regKey),
      hklmValueName: r.regName,
      hklmValueKind: r.regValueKind,
      hklmValueLiteral: r.regValueLiteral,
      hklmDestroy: destroy)
  of srkWindowsOptionalFeature:
    PrivilegedOperation(kind: pokWindowsOptionalFeature, address: r.address,
      featureName: r.featureName,
      featureEnable: (if destroy: false else: r.featureEnabled))
  of srkWindowsCapability:
    PrivilegedOperation(kind: pokWindowsCapability, address: r.address,
      capabilityName: r.capabilityName,
      capabilityInstall: (if destroy: false else: r.capabilityInstalled))
  of srkWindowsService:
    PrivilegedOperation(kind: pokWindowsService, address: r.address,
      serviceName: r.serviceName,
      serviceStartType: r.serviceStartType,
      serviceRunning: r.serviceRunning,
      serviceDisplayName: r.serviceDisplayName,
      serviceBinPath: r.serviceBinPath,
      serviceRecoveryActions: r.serviceRecoveryActions,
      serviceRecoveryResetSeconds: r.serviceRecoveryResetSeconds)
  of srkWindowsScheduledTask:
    PrivilegedOperation(kind: pokWindowsScheduledTask, address: r.address,
      wstTaskName: r.wstTaskName,
      wstExecutable: r.wstExecutable,
      wstArguments: r.wstArguments,
      wstWorkingDirectory: r.wstWorkingDirectory,
      wstRunAsUser: r.wstRunAsUser,
      wstRunWithHighestPrivileges: r.wstRunWithHighestPrivileges,
      wstSchedule: r.wstSchedule,
      wstEnabled: r.wstEnabled,
      wstDestroy: destroy)
  of srkWindowsVsInstaller:
    PrivilegedOperation(kind: pokWindowsVsInstaller, address: r.address,
      vsEdition: r.vsEdition,
      vsChannel: r.vsChannel,
      vsInstallPath: r.vsInstallPath,
      vsWorkloads: r.vsWorkloads,
      vsComponents: r.vsComponents,
      vsStrict: r.vsStrict,
      vsDestroy: destroy)
  of srkWindowsFirewallRule:
    PrivilegedOperation(kind: pokWindowsFirewallRule, address: r.address,
      fwName: r.fwName,
      fwDisplayName: r.fwDisplayName,
      fwProtocol: r.fwProtocol,
      fwDirection: r.fwDirection,
      fwAction: r.fwAction,
      fwLocalPort: r.fwLocalPort,
      fwEnabled: r.fwEnabled,
      fwDestroy: destroy)
  of srkWindowsAcl:
    PrivilegedOperation(kind: pokWindowsAcl, address: r.address,
      aclPath: r.aclPath,
      aclOwner: r.aclOwner,
      aclEntries: r.aclEntries,
      aclInheritanceMode: r.aclInheritanceMode,
      aclDestroy: destroy)
  of srkMacosSystemDefault:
    PrivilegedOperation(kind: pokMacosSystemDefault, address: r.address,
      sdDomain: r.sdDomain,
      sdKey: r.sdKey,
      sdValueType: r.sdValueType,
      sdValueLiteral: r.sdValueLiteral,
      sdRestartTarget: r.sdRestartTarget,
      sdDestroy: destroy)
  of srkSystemdSystemUnit:
    PrivilegedOperation(kind: pokSystemdSystemUnit, address: r.address,
      suName: r.suName,
      suContent: renderedSystemUnitContent(r),
      suEnabled: r.suEnabled,
      suAptClosureLock: r.suAptClosureLock,
      suRestartHeld: r.suRestartHeld,
      suDestroy: destroy)
  of srkLaunchdSystemDaemon:
    PrivilegedOperation(kind: pokLaunchdSystemDaemon, address: r.address,
      sdaLabel: r.sdaLabel,
      sdaProgramArgs: r.sdaProgramArgs,
      sdaRunAtLoad: r.sdaRunAtLoad,
      sdaDestroy: destroy)
  of srkFsSystemFile:
    PrivilegedOperation(kind: pokFsSystemFile, address: r.address,
      sfPath: r.sfPath,
      sfContent: r.sfContent,
      sfSourceUrl: r.sfSourceUrl,
      sfSha256: r.sfSha256,
      sfSourceLocal: r.sfSourceLocal,
      sfDestroy: destroy)
  of srkFsSystemDirectory:
    PrivilegedOperation(kind: pokFsSystemDirectory, address: r.address,
      fsdPath: r.dirPath,
      fsdAclPresent: r.dirAclPresent,
      fsdAclOwner: r.dirAclOwner,
      fsdAclEntries: r.dirAclEntries,
      fsdAclInheritance: r.dirAclInheritance,
      fsdDestroy: destroy)
  of srkEnvSystemVariable:
    PrivilegedOperation(kind: pokEnvSystemVariable, address: r.address,
      evName: r.evName,
      evContribution: r.evContribution,
      evIsPathList: r.evIsPathList,
      evDestroy: destroy)
  of srkPasswdUser:
    PrivilegedOperation(kind: pokPasswdUser, address: r.address,
      puName: r.puName,
      puHome: r.puHome,
      puShell: r.puShell,
      puGroups: r.puGroups,
      puDestroy: destroy)
  of srkOsTimezone:
    PrivilegedOperation(kind: pokOsTimezone, address: r.address,
      tzIana: r.tzIana)
  of srkOsHostname:
    PrivilegedOperation(kind: pokOsHostname, address: r.address,
      hostnameName: r.hostnameName)
  of srkLinuxSysctl:
    PrivilegedOperation(kind: pokLinuxSysctl, address: r.address,
      sysctlKey: r.sysctlKey,
      sysctlValue: r.sysctlValue,
      sysctlFilename: r.sysctlFilename,
      sysctlDestroy: destroy)
  of srkLinuxUdevRule:
    PrivilegedOperation(kind: pokLinuxUdevRule, address: r.address,
      udevName: r.udevName,
      udevContent: r.udevContent,
      udevDestroy: destroy)
  of srkLinuxPolkitRule:
    PrivilegedOperation(kind: pokLinuxPolkitRule, address: r.address,
      polkitName: r.polkitName,
      polkitContent: r.polkitContent,
      polkitDestroy: destroy)
  of srkLinuxTmpfilesRule:
    PrivilegedOperation(kind: pokLinuxTmpfilesRule, address: r.address,
      tmpfilesName: r.tmpfilesName,
      tmpfilesContent: r.tmpfilesContent,
      tmpfilesApplyNow: r.tmpfilesApplyNow,
      tmpfilesDestroy: destroy)
  of srkLinuxSudoersRule:
    PrivilegedOperation(kind: pokLinuxSudoersRule, address: r.address,
      sudoersName: r.sudoersName,
      sudoersContent: r.sudoersContent,
      sudoersDestroy: destroy)
  of srkPasswdGroup:
    PrivilegedOperation(kind: pokPasswdGroup, address: r.address,
      pgName: r.pgName,
      pgGid: r.pgGid,
      pgMembers: r.pgMembers,
      pgDestroy: destroy)
  of srkLinuxNixDaemonSetting:
    PrivilegedOperation(kind: pokLinuxNixDaemonSetting, address: r.address,
      nixKey: r.nixKey,
      nixValue: r.nixValue,
      nixFilename: r.nixFilename,
      nixDestroy: destroy)
  of srkSystemdSystemTimer:
    PrivilegedOperation(kind: pokSystemdSystemTimer, address: r.address,
      stName: r.stName,
      stContent: r.stContent,
      stEnabled: r.stEnabled,
      stRunning: r.stRunning,
      stDestroy: destroy)
  of srkLinuxFirewallRule:
    PrivilegedOperation(kind: pokLinuxFirewallRule, address: r.address,
      lfwChain: r.lfwChain,
      lfwName: r.lfwName,
      lfwProtocol: r.lfwProtocol,
      lfwDirection: r.lfwDirection,
      lfwLocalPort: r.lfwLocalPort,
      lfwAction: r.lfwAction,
      lfwDestroy: destroy)
  of srkLinuxNixosSystemModule:
    PrivilegedOperation(kind: pokLinuxNixosSystemModule, address: r.address,
      nixosModuleName: r.nixosModuleName,
      nixosModuleContent: r.nixosModuleContent,
      nixosModuleDestroy: destroy)
  of srkMacosDarwinSystemModule:
    PrivilegedOperation(kind: pokMacosDarwinSystemModule, address: r.address,
      darwinModuleName: r.darwinModuleName,
      darwinModuleContent: r.darwinModuleContent,
      darwinModuleDestroy: destroy)
  of srkSystemdUnitState:
    PrivilegedOperation(kind: pokSystemdUnitState, address: r.address,
      usName: r.usName,
      usEnabled: r.usEnabled,
      usRunning: r.usRunning,
      usDestroy: destroy)
  of srkLinuxAddOnTool:
    PrivilegedOperation(kind: pokLinuxAddOnTool, address: r.address,
      atCommand: r.atCommand,
      atAptClosureLock: r.atAptClosureLock,
      atProgram: r.atProgram,
      atDestroy: destroy)
  of srkSystemdSystemDropIn:
    PrivilegedOperation(kind: pokSystemdSystemDropIn, address: r.address,
      diUnit: r.diUnit,
      diName: r.diName,
      diContent: r.diContent,
      diDestroy: destroy)
  of srkLinuxSysusersEntry:
    PrivilegedOperation(kind: pokLinuxSysusersEntry, address: r.address,
      seName: r.seName,
      seContent: sysusersEntryContent(r),
      seDestroy: destroy)
  of srkLinuxFhsSandbox:
    PrivilegedOperation(kind: pokLinuxFhsSandbox, address: r.address,
      fsbBinPath: r.fsbBinPath,
      fsbFhsTreeRoots: r.fsbFhsTreeRoots,
      fsbArgv: r.fsbArgv,
      fsbDestroy: destroy)
  of srkLinuxDpkgDiversion:
    PrivilegedOperation(kind: pokLinuxDpkgDiversion, address: r.address,
      ddPath: r.ddPath,
      ddDestroy: destroy)

proc isDestructiveRollback*(r: SystemResource): bool =
  ## True when rolling this resource back would disable an Optional
  ## Feature, uninstall a Capability, or uninstall a Visual Studio
  ## product — the operations `--accept-feature-destroy` gates.
  ## `passwd.user` is handled by the SEPARATE `--accept-passwd-destroy`
  ## gate (`requiresPasswdDestroy`), not this one.
  r.kind in {srkWindowsOptionalFeature, srkWindowsCapability,
    srkWindowsVsInstaller}

proc requiresPasswdDestroy*(r: SystemResource): bool =
  ## True when rolling this resource back would REMOVE a user account
  ## or a group — the operation `--accept-passwd-destroy` gates (the
  ## symmetric counterpart of `--accept-feature-destroy`). A
  ## `passwd.user` destroy deletes a real account; a `passwd.group`
  ## destroy can break file ownership for files chown'd to that gid.
  ## Both are gated even when the account / group was created by a
  ## prior apply.
  r.kind in {srkPasswdUser, srkPasswdGroup}
