## The effective-unit check of the hardening floor (ReproOS Add-On Mode
## spec §10.1, amended by A9's review round 3).
##
## The floor's parse-time checks (``repro_infra/service_floor``) predict
## how systemd will read a unit and its drop-ins. Three review rounds
## found a spelling, a key, a drop-in rule or a default they predicted
## wrong. This module makes systemd's own parser the authority: after the
## switch's ``daemon-reload`` and before step 7 starts anything (at apply,
## revert, rollback and replay alike), each floored unit's effective
## properties are read with ``systemctl show`` and compared with the floor
## the unit was rendered under -- the floor block the add-on wrote into its
## unit file (``floorBlock``), minus the unit's named exceptions. A unit
## that does not hold its floor, by its own lines, a drop-in, a host's
## drop-in or a default, is a problem of the switch: nothing starts, and
## the switch reverts (``EAddOnFloorNotEffective``).
##
## What is compared, per floor version (the floor the unit was stored
## under, never today's):
##
## * every version: each setting of the floor block (``NoNewPrivileges``,
##   ``ProtectSystem``, ``MemoryDenyWriteExecute`` ... as systemd shows
##   them), its ``NoExecPaths`` entries present, its ``ExecPaths`` exactly,
##   its ``ReadOnlyPaths`` present, an allow-list ``SystemCallFilter`` that
##   holds none of the floor's denied calls (the caller expands the deny
##   line with the base's own ``systemd-analyze syscall-filter``), its
##   capability sets, address families and ``DynamicUser=yes``; and no
##   drop-in the add-on did not install, outside the distribution's own
##   ``/usr/lib/systemd`` (``DropInPaths``);
## * from version 2 (which refused root): the service does not run as
##   root -- ``DynamicUser=yes`` or a ``User=`` that resolves to a non-zero
##   uid, ``Group=`` not root, no privileged supplementary group -- and no
##   other root;
## * from version 4: no ``PAMName=``, no image or extension mounted in,
##   and every writable place the unit has (``ReadWritePaths=``,
##   ``BindPaths=`` destinations, ``TemporaryFileSystem=``, each
##   ``*Directory=``) named in ``NoExecPaths=`` and not over an
##   ``ExecPaths=`` entry.
##
## The value forms are what ``systemctl show`` prints on systemd 252, 255,
## 257 and 259 (measured identical: A9 review round 3's experiment), e.g.
## ``BindPaths=/var/lib/x:/srv/y:rbind``, ``TemporaryFileSystem=/srv/t:mode=1777``,
## ``User=`` (empty) with ``DynamicUser=no`` for a unit that runs as root.
## systemd will not show a template (``foo@.service``); the caller checks
## the instances the generation names.

import std/[algorithm, os, posix, sequtils, sets, strutils, tables]

import ./host_exec
import ./mutations
from ./fingerprint import sha256OfFile

import repro_infra/service_floor
import repro_infra/service_account

type
  ShowProps* = Table[string, string]
    ## ``systemctl show`` as key -> value (the last line of a key).
  ShowLines* = Table[string, seq[string]]
    ## ``systemctl show`` as key -> every line of it, in order (a command
    ## property has one line per command).

const
  StartHoldName* = "zz-repro-addon-floor-hold.conf"
    ## The runtime drop-in the switch writes for every floored unit before
    ## step 6's reload and removes once the unit passes this check (spec
    ## §10.1, A9 review round 4, finding 7): an assertion that always
    ## fails, so nothing -- a socket, a timer, a path unit, D-Bus or a
    ## ``Wants=`` -- can start the unit in between.
  StartHoldAssertion* =
    when mutated("hold-path-creatable"):
      # Falsifying build: round 4's assertion, a path a unit can create
      # (a listener, a RuntimeDirectory=) and so satisfy for every unit.
      "AssertPathExists=/run/repro/floor-hold/never"
    else:
      "AssertPathExists=!/"
    ## The hold's assertion (A9 review round 7, finding 2): that ``/`` does
    ## not exist. systemd.unit(5): a path prefixed with ``!`` negates the
    ## test, and the unit starts only if the path does not exist. ``/`` is
    ## the root of PID 1's mount namespace, in which the manager checks the
    ## assertion; it exists for as long as the manager runs and no unit can
    ## remove or replace it (``rmdir("/")`` fails with ``EBUSY``,
    ## rmdir(2)), so nothing any unit creates or removes can satisfy the
    ## hold. A rename into ``/`` is impossible for the same reason.
  StartHoldText* = "# Written by the ReproOS add-on switch: the unit may not " &
    "start until its\n# effective configuration has been checked against " &
    "its hardening floor.\n[Unit]\n" & StartHoldAssertion & "\n"
  CredentialRoot* = "/run/repro/secrets"
    ## Where the add-on stages a service's credentials (``profile``'s
    ## ``SecretsRunRoot``): ``LoadCredential=`` may read only
    ## ``<root>/<service>/``.
  FloorMarker* = "# serviceFloor (ReproOS add-on hardening default)"
  ScalarFloorKeys* = ["NoNewPrivileges", "ProtectSystem", "ProtectHome",
    "PrivateTmp", "PrivateDevices", "ProtectKernelTunables",
    "ProtectKernelModules", "ProtectKernelLogs", "ProtectControlGroups",
    "ProtectClock", "ProtectHostname", "ProtectProc", "RestrictNamespaces",
    "RestrictRealtime", "RestrictSUIDSGID", "LockPersonality",
    "MemoryDenyWriteExecute", "SystemCallArchitectures", "UMask"]
  DirectoryRoots* = [("StateDirectory", "/var/lib"),
                    ("RuntimeDirectory", "/run"),
                    ("CacheDirectory", "/var/cache"),
                    ("LogsDirectory", "/var/log"),
                    ("ConfigurationDirectory", "/etc")]
  ExecProps* = ["ExecCondition", "ExecStartPre", "ExecStart", "ExecStartPost",
                "ExecReload", "ExecReloadPost", "ExecStop", "ExecStopPost"]
    ## The command properties. Each is shown twice: ``<Key>`` and
    ## ``<Key>Ex``, the second with the command's flags (``+`` is
    ## ``privileged``, ``!`` ``no-setuid``, ``!!`` ``ambient``, ``-``
    ## ``ignore-failure``, ``:`` ``no-env-expand``).
  AllowedExecFlags = ["ignore-failure", "no-env-expand"]
    ## The flags a floored unit's command may carry: neither changes the
    ## credentials or the sandbox the command runs under.
  AllowedStdin = ["null", "socket", "fd", "data"]
  AllowedStdout = ["inherit", "null", "journal", "kmsg", "journal+console",
                   "kmsg+console", "socket", "fd"]
    ## ``StandardInput=`` / ``StandardOutput=`` / ``StandardError=`` that
    ## open nothing by path: ``file:``, ``append:``, ``truncate:`` and
    ## ``tty`` are opened by the service manager, as root, before the
    ## sandbox (A9 review round 4, finding 3: ``StandardOutput=truncate:``
    ## wrote into ``/etc``).

  ComparedProps* = ["LoadState", "FragmentPath", "SourcePath", "DropInPaths",
    "OnFailureJobMode", "OnSuccessJobMode", "AllowIsolate",
    "User", "Group", "DynamicUser", "SupplementaryGroups", "PAMName",
    "NoNewPrivileges", "ProtectSystem", "ProtectHome", "PrivateTmp",
    "PrivateDevices", "ProtectKernelTunables", "ProtectKernelModules",
    "ProtectKernelLogs", "ProtectControlGroups", "ProtectClock",
    "ProtectHostname", "ProtectProc", "RestrictNamespaces", "RestrictRealtime",
    "RestrictSUIDSGID", "LockPersonality", "MemoryDenyWriteExecute",
    "SystemCallArchitectures", "SystemCallFilter",
    "CapabilityBoundingSet", "AmbientCapabilities", "UMask",
    "RestrictAddressFamilies", "NoExecPaths", "ExecPaths", "ReadOnlyPaths",
    "ReadWritePaths", "BindPaths", "BindReadOnlyPaths", "TemporaryFileSystem",
    "StateDirectory", "RuntimeDirectory", "CacheDirectory", "LogsDirectory",
    "ConfigurationDirectory", "RootDirectory", "RootImage", "RootEphemeral",
    "RootHash", "RootHashSignature", "RootVerity",
    "MountImages", "ExtensionImages", "ExtensionDirectories", "OpenFile",
    "StandardInput", "StandardOutput", "StandardError", "TTYPath",
    "SecureBits", "KeyringMode", "Personality", "RootDirectoryStartOnly",
    "JoinsNamespaceOf", "NetworkNamespacePath", "IPCNamespacePath",
   
    "EnvironmentFiles", "DeviceAllow", "Delegate", "CoredumpReceive",
    "BPFProgram", "USBFunctionDescriptors", "USBFunctionStrings",
    "ExecSearchPath", "Transient",
    "SELinuxContext", "AccessSELinuxContext", "AppArmorProfile",
    "SmackProcessLabel", "MountFlags", "RootHashPath", "RootHashSignaturePath",
    "UserNamespacePath", "BPFDelegateCommands", "BPFDelegateMaps",
    "BPFDelegatePrograms", "BPFDelegateAttachments", "StateDirectorySymlink",
    "RuntimeDirectorySymlink", "CacheDirectorySymlink", "LogsDirectorySymlink",
    "FailureAction", "SuccessAction",
    "StartLimitAction", "JobTimeoutAction", "CPUSchedulingPolicy",
    "IOSchedulingClass"]
    ## The properties the check compares with the floor (each one's rule is
    ## in ``effectiveFloorProblems``), together with ``ExecProps`` and their
    ## ``Ex`` forms.

  InertProps* = [
    # Identity, documentation and the unit's runtime state.
    "Id", "Names", "Description", "Documentation", "Following", "Perpetual",
    "UnitFileState", "UnitFilePreset", "ActiveState", "SubState",
    "FreezerState", "Result", "CleanResult", "ReloadResult", "LiveMountResult",
    "InvocationID", "NeedDaemonReload", "StatusText", "StatusErrno",
    "StatusBusError", "StatusVarlinkError", "NRestarts", "MainPID",
    "ControlPID", "ControlGroup", "ControlGroupId", "ExecMainPID",
    "ExecMainCode", "ExecMainStatus", "ConditionResult", "AssertResult",
    "Conditions", "Asserts", "CanStart", "CanStop", "CanReload", "CanIsolate",
    "CanClean", "CanFreeze", "CanLiveMount", "Markers", "Refs", "JobId",
    "NFileDescriptorStore", "RestartUSecNext", "MemoryAvailable",
    "EffectiveMemoryHigh", "EffectiveMemoryMax", "EffectiveTasksMax",
    "EffectiveCPUs", "EffectiveMemoryNodes", "OOMKills", "ManagedOOMKills",
    "UID", "GID", "DelegateControllers", "DelegateSubgroup",
    "DelegateNamespaces", "ActivationDetails", "Job", "LoadError", "SliceOf",
    "StateDirectoryQuotaUsage", "CacheDirectoryQuotaUsage",
    "LogsDirectoryQuotaUsage", "DisableControllers", "BlockIODeviceWeight",
    "BlockIOReadBandwidth", "BlockIOWriteBandwidth",
    "ExtraFileDescriptorNames",
    # Dependencies and ordering: which other units start with this one or
    # after it, not what this one may do.
    "Requires", "Requisite", "Wants", "BindsTo", "PartOf", "Upholds",
    "RequiredBy", "RequisiteOf", "WantedBy", "BoundBy", "UpheldBy",
    "ConsistsOf", "Conflicts", "ConflictedBy", "Before", "After",
    "OnSuccess", "OnSuccessOf", "OnFailure", "OnFailureOf", "Triggers",
    "TriggeredBy", "PropagatesReloadTo", "ReloadPropagatedFrom",
    "PropagatesStopTo", "StopPropagatedFrom", "RequiresMountsFor",
    "WantsMountsFor", "Slice", "DefaultDependencies", "StopWhenUnneeded",
    "RefuseManualStart", "RefuseManualStop",
    "IgnoreOnIsolate", "CollectMode", "SurviveFinalKillSignal",
    # Start, stop and restart policy, timeouts and signals.
    "Type", "ExitType", "Restart", "RestartMode", "RestartUSec",
    "RestartSteps", "RestartMaxDelayUSec", "RestartPreventExitStatus",
    "RestartForceExitStatus", "SuccessExitStatus", "RemainAfterExit",
    "GuessMainPID", "PIDFile", "BusName", "NotifyAccess", "TimeoutStartUSec",
    "TimeoutStopUSec", "TimeoutAbortUSec", "TimeoutCleanUSec",
    "TimeoutStartFailureMode", "TimeoutStopFailureMode", "RuntimeMaxUSec",
    "RuntimeRandomizedExtraUSec", "WatchdogUSec", "WatchdogSignal",
    "JobTimeoutUSec", "JobRunningTimeoutUSec",
    "JobTimeoutRebootArgument", "StartLimitIntervalUSec", "StartLimitBurst",
    "FailureActionExitStatus", "SuccessActionExitStatus", "RebootArgument",
    "KillMode", "KillSignal", "RestartKillSignal", "FinalKillSignal",
    "SendSIGKILL", "SendSIGHUP", "ReloadSignal", "OOMPolicy",
    "OOMScoreAdjust", "FileDescriptorStoreMax", "FileDescriptorStorePreserve",
    "SameProcessGroup", "IgnoreSIGPIPE", "NonBlocking", "UtmpIdentifier",
    "UtmpMode", "TTYReset", "TTYVHangup", "TTYVTDisallocate", "TTYRows",
    "TTYColumns", "SetLoginEnvironment", "DebugInvocation",
    # Resource control: how much the service may use, not what it may do.
    "CPUAccounting", "CPUWeight", "StartupCPUWeight", "CPUShares",
    "StartupCPUShares", "CPUQuotaPerSecUSec", "CPUQuotaPeriodUSec",
    "AllowedCPUs", "StartupAllowedCPUs", "AllowedMemoryNodes",
    "StartupAllowedMemoryNodes", "CPUUsageNSec", "IOAccounting", "IOWeight",
    "StartupIOWeight", "IODeviceWeight", "IOReadBandwidthMax",
    "IOWriteBandwidthMax", "IOReadIOPSMax", "IOWriteIOPSMax",
    "IODeviceLatencyTargetUSec", "IOReadBytes", "IOReadOperations",
    "IOWriteBytes", "IOWriteOperations", "BlockIOAccounting", "BlockIOWeight",
    "StartupBlockIOWeight", "MemoryAccounting", "DefaultMemoryLow",
    "DefaultStartupMemoryLow", "DefaultMemoryMin", "MemoryMin", "MemoryLow",
    "StartupMemoryLow", "MemoryHigh", "StartupMemoryHigh", "MemoryMax",
    "StartupMemoryMax", "MemorySwapMax", "StartupMemorySwapMax",
    "MemoryZSwapMax", "StartupMemoryZSwapMax", "MemoryZSwapWriteback",
    "MemoryLimit", "MemoryCurrent", "MemoryPeak", "MemorySwapCurrent",
    "MemorySwapPeak", "MemoryZSwapCurrent", "MemoryKSM",
    "MemoryPressureWatch", "MemoryPressureThresholdUSec", "TasksAccounting",
    "TasksCurrent", "TasksMax", "IPAccounting", "IPIngressBytes",
    "IPIngressPackets", "IPEgressBytes", "IPEgressPackets",
    "ManagedOOMSwap", "ManagedOOMMemoryPressure",
    "ManagedOOMMemoryPressureLimit", "ManagedOOMMemoryPressureDurationUSec",
    "ManagedOOMPreference", "CoredumpFilter", "TimerSlackNSec", "Nice",
    "CPUSchedulingPriority", "CPUSchedulingResetOnFork", "CPUAffinity", "CPUAffinityFromNUMA",
    "NUMAPolicy", "NUMAMask", "IOSchedulingPriority",
    "StateDirectoryAccounting", "StateDirectoryQuota",
    "CacheDirectoryAccounting", "CacheDirectoryQuota",
    "LogsDirectoryAccounting", "LogsDirectoryQuota",
    # Logging.
    "SyslogPriority", "SyslogIdentifier", "SyslogLevelPrefix",
    "SyslogLevel", "SyslogFacility", "LogLevelMax", "LogRateLimitIntervalUSec",
    "LogRateLimitBurst", "LogExtraFields", "LogFilterPatterns",
    "LogNamespace", "SystemCallLog",
    # The errno a denied call returns instead of the kill: the call is
    # still denied either way.
    "SystemCallErrorNumber", "StandardInputFileDescriptorName",
    "StandardOutputFileDescriptorName", "StandardErrorFileDescriptorName",
    "StandardInputData",
    # Settings that only restrict the service further (the floor's own
    # restrictions are compared; these add to them).
    "InaccessiblePaths", "PrivateNetwork", "PrivateUsers", "PrivateUsersEx",
    "PrivateIPC", "PrivateMounts", "PrivatePIDs", "PrivateBPF",
    "PrivateTmpEx", "ProtectControlGroupsEx", "ProtectHostnameEx",
    "RemoveIPC", "ProcSubset", "DevicePolicy", "IPAddressAllow",
    "IPAddressDeny", "IPIngressFilterPath", "IPEgressFilterPath",
    "SocketBindAllow", "SocketBindDeny", "RestrictNetworkInterfaces",
    "RestrictFileSystems", "MountAPIVFS", "BindLogSockets",
    "RootImagePolicy", "MountImagePolicy", "ExtensionImagePolicy",
    "StateDirectoryMode", "RuntimeDirectoryMode", "CacheDirectoryMode",
    "LogsDirectoryMode", "ConfigurationDirectoryMode",
    "RuntimeDirectoryPreserve",
    # The service's own environment and working directory. What a variable
    # can make the service run is bounded by the exec confinement (every
    # mount but the closure is noexec), and the directory is entered as
    # the service's own user.
    "Environment", "PassEnvironment", "UnsetEnvironment", "WorkingDirectory",
    # Timestamps, each by name (round 5: no family wildcard).
    "ActiveEnterTimestamp", "ActiveEnterTimestampMonotonic",
    "ActiveExitTimestamp", "ActiveExitTimestampMonotonic", "AssertTimestamp",
    "AssertTimestampMonotonic", "ConditionTimestamp",
    "ConditionTimestampMonotonic", "ExecMainExitTimestamp",
    "ExecMainExitTimestampMonotonic", "ExecMainHandoffTimestamp",
    "ExecMainHandoffTimestampMonotonic", "ExecMainStartTimestamp",
    "ExecMainStartTimestampMonotonic", "InactiveEnterTimestamp",
    "InactiveEnterTimestampMonotonic", "InactiveExitTimestamp",
    "InactiveExitTimestampMonotonic", "StateChangeTimestamp",
    "StateChangeTimestampMonotonic", "WatchdogTimestamp",
    "WatchdogTimestampMonotonic"]
    ## The properties reviewed as unable to change the service's
    ## credentials, its sandbox, the files it can reach or what it executes
    ## (spec §10.1, A9 review round 4). A property ``systemctl show``
    ## reports that is in neither this list, ``ComparedProps`` nor
    ## ``ExecProps`` refuses the unit, so a setting a newer systemd adds is
    ## refused until it is reviewed. Timestamps (``*Timestamp``,
    ## ``*TimestampMonotonic``) and resource limits (``Limit*``: rlimits,
    ## which only lower what the service may use) are reviewed as
    ## families until round 5; every name is now listed (A9 review round 5,
    ## finding 3), and a ``Limit*`` is compared with the manager's default
    ## (``LimitProps``).

const LimitProps* = [
    "LimitAS", "LimitASSoft", "LimitCORE", "LimitCORESoft", "LimitCPU",
    "LimitCPUSoft", "LimitDATA", "LimitDATASoft", "LimitFSIZE",
    "LimitFSIZESoft", "LimitLOCKS", "LimitLOCKSSoft", "LimitMEMLOCK",
    "LimitMEMLOCKSoft", "LimitMSGQUEUE", "LimitMSGQUEUESoft", "LimitNICE",
    "LimitNICESoft", "LimitNOFILE", "LimitNOFILESoft", "LimitNPROC",
    "LimitNPROCSoft", "LimitRSS", "LimitRSSSoft", "LimitRTPRIO",
    "LimitRTPRIOSoft", "LimitRTTIME", "LimitRTTIMESoft", "LimitSIGPENDING",
    "LimitSIGPENDINGSoft", "LimitSTACK", "LimitSTACKSoft"]
    ## The resource limits: each compared with the service manager's own
    ## default (``DefaultLimit<X>``), which a unit may lower but not raise
    ## (``LimitMEMLOCK=infinity`` raises it; A9 review round 5, finding 3).

const
  FileJudgedProps* = ["LoadCredential", "LoadCredentialEncrypted",
    "ImportCredential", "ImportCredentialEx", "NFTSet", "RootImageOptions",
    "SetCredential", "SetCredentialEncrypted", "Sockets"]
    ## Settings ``systemctl show`` reports as ``[unprintable]`` (measured on
    ## systemd 252, 255, 257 and 259; A9 review round 6, finding 4), or do
    ## not print at all (``Sockets=``, reported only as the socket's
    ## ``Triggers=``): their
    ## rules read the files systemd loaded (``EffectiveInput.loaded``),
    ## which provenance holds to the generation's own bytes.

  RequiredProps* = [
    "LoadState", "FragmentPath", "SourcePath", "DropInPaths", "User",
    "Group", "DynamicUser", "SupplementaryGroups", "PAMName",
    "NoNewPrivileges", "ProtectSystem", "ProtectHome", "PrivateTmp",
    "PrivateDevices", "ProtectKernelTunables", "ProtectKernelModules",
    "ProtectKernelLogs", "ProtectControlGroups", "ProtectClock",
    "ProtectHostname", "ProtectProc", "RestrictNamespaces",
    "RestrictRealtime", "RestrictSUIDSGID", "LockPersonality",
    "MemoryDenyWriteExecute", "SystemCallArchitectures", "SystemCallFilter",
    "CapabilityBoundingSet", "AmbientCapabilities", "UMask",
    "RestrictAddressFamilies", "NoExecPaths", "ExecPaths", "ReadOnlyPaths",
    "ReadWritePaths", "BindPaths", "BindReadOnlyPaths",
    "TemporaryFileSystem", "StateDirectory", "RuntimeDirectory",
    "CacheDirectory", "LogsDirectory", "ConfigurationDirectory",
    "RootDirectory", "RootImage", "RootHash", "RootHashSignature",
    "RootVerity", "MountImages", "ExtensionImages", "ExtensionDirectories",
    "StandardInput", "StandardOutput", "StandardError", "TTYPath",
    "SecureBits", "KeyringMode", "Personality", "RootDirectoryStartOnly",
    "JoinsNamespaceOf", "NetworkNamespacePath", "IPCNamespacePath",
    "Delegate", "USBFunctionDescriptors", "USBFunctionStrings",
    "ExecSearchPath", "Transient", "SELinuxContext", "AccessSELinuxContext",
    "AppArmorProfile", "SmackProcessLabel", "MountFlags", "RootHashPath",
    "RootHashSignaturePath", "FailureAction", "SuccessAction",
    "StartLimitAction", "JobTimeoutAction", "CPUSchedulingPolicy",
    "IOSchedulingClass"]
    ## The compared properties every supported systemd prints under
    ## ``systemctl show --all`` for a unit that sets none of them
    ## (``fixtures/systemd_properties/show-all-minimal-*``, all four
    ## bases): absent, they
    ## refuse, never pass (A9 review round 6, finding 3). The other
    ## compared properties are printed only when set, or only by newer
    ## systemd.

proc isInertProp*(k: string): bool =
  when mutated("inert-families-by-pattern"):
    # Falsifying build: round 4's family wildcards.
    if k.endsWith("Timestamp") or k.endsWith("TimestampMonotonic") or
        k.startsWith("Limit"): return true
  k in InertProps

proc isExecProp*(k: string): bool =
  k in ExecProps or (k.endsWith("Ex") and k[0 ..< k.len - 2] in ExecProps)

proc parseShow*(text: string): ShowProps =
  ## ``key=value`` lines (the order differs between systemd versions). A
  ## key systemd prints on several lines (``EnvironmentFiles=``,
  ## ``*DirectorySymlink=``, ``BindPaths=`` ... one entry per line) gets
  ## every value, space-separated, so every entry is judged; round 5 kept
  ## only the last line (A9 review round 6, finding 2).
  for l in text.splitLines():
    let eq = l.find('=')
    if eq <= 0: continue
    let k = l[0 ..< eq]
    let v = l[eq + 1 .. ^1]
    when mutated("show-last-line-only"):
      result[k] = v
    else:
      if k in result and result[k].len > 0 and v.len > 0:
        result[k] = result[k] & " " & v
      elif k notin result or v.len > 0:
        result[k] = v

proc parseShowLines*(text: string): ShowLines =
  ## Every ``key=value`` line, per key in order.
  for l in text.splitLines():
    let eq = l.find('=')
    if eq > 0: result.mgetOrPut(l[0 ..< eq], @[]).add(l[eq + 1 .. ^1])

proc showUnitText*(unit: string): string =
  ## Everything ``systemctl show`` reports for ``unit`` (every property
  ## with a value; raises when systemd will not show it). Run through
  ## ``host_exec`` (the distribution's systemctl by absolute path, a fixed
  ## environment).
  let r = runSystemctl(["show", "--all", "--no-pager", "--", unit])
  if r.exitCode != 0:
    raise newException(OSError, "systemctl show " & unit & ": " &
                       r.output.strip())
  r.output

proc showUnit*(unit: string): ShowProps =
  parseShow(showUnitText(unit))

proc execEntries*(lines: ShowLines; key: string):
    seq[tuple[path: string; flags: seq[string]]] =
  ## The commands of ``<key>Ex`` (``{ path=... ; argv[]=... ; flags=... ;
  ## ... }``), each with its executable and flags.
  for l in lines.getOrDefault(key & "Ex"):
    var path = ""
    var flags: seq[string]
    for part in l.strip(chars = {'{', '}', ' '}).split(" ; "):
      let p = part.strip()
      if p.startsWith("path="): path = p[5 .. ^1]
      elif p.startsWith("flags="): flags = p[6 .. ^1].splitWhitespace()
    result.add((path: path, flags: flags))

proc floorBlock*(rendered: string): Table[string, seq[string]] =
  ## The settings of the floor block the add-on rendered into a unit file:
  ## every ``key=value`` line from ``FloorMarker`` to the end of its
  ## ``[Service]`` section, comments skipped; a key's lines in order.
  var inBlock = false
  for raw in rendered.splitLines():
    let l = raw.strip()
    if l == FloorMarker:
      inBlock = true
      continue
    if not inBlock: continue
    if l.startsWith("[") and l.endsWith("]"): break
    if l.len == 0 or l[0] in {'#', ';'}: continue
    let eq = l.find('=')
    if eq <= 0: continue
    result.mgetOrPut(l[0 ..< eq], @[]).add(l[eq + 1 .. ^1])

proc exceptionKeys*(exceptions: openArray[string]): HashSet[string] =
  ## The settings ``floorExceptions`` names (``Setting: why`` /
  ## ``Setting+values: why``).
  for e in exceptions:
    var k = e.split(':', 1)[0].strip()
    let plus = k.find('+')
    if plus > 0: k = k[0 ..< plus].strip()
    result.incl(k)

proc words(v: string): seq[string] = v.splitWhitespace()

proc pathSet(v: string): HashSet[string] =
  for t in words(v):
    let q = t.strip(leading = true, trailing = false, chars = {'-', '+'})
    if q.len > 0: result.incl(normalisedPath(q))

proc versionNumber(version: string): int =
  ## ``1``, ``2`` / ``2-prekeep``, ``3``, ``4``; "" is today's.
  let v = if version.len == 0: FloorVersion else: version
  try: parseInt(v.split('-')[0]) except ValueError: 0

proc writablePlaces*(show: ShowProps): seq[string] =
  ## Every place the unit can write that systemd sets up for it, as
  ## systemd shows them: ``ReadWritePaths=``, each writable bind's
  ## destination (``BindPaths=``; a ``BindReadOnlyPaths=`` one is not)
  ## (``[-]src:dst:opts``), each tmpfs (``path:opts``), each
  ## ``*Directory=`` under its root.
  for t in words(show.getOrDefault("ReadWritePaths")):
    result.add(t.strip(leading = true, trailing = false, chars = {'-', '+'}))
  # BindReadOnlyPaths= destinations are read-only (an apt closure's /usr
  # is one): not writable places (A9 review round 4, finding 5).
  for k in ["BindPaths"]:
    for t in words(show.getOrDefault(k)):
      let parts = t.strip(leading = true, trailing = false,
                          chars = {'-', '+'}).split(':')
      result.add(if parts.len >= 2: parts[1] else: parts[0])
  for t in words(show.getOrDefault("TemporaryFileSystem")):
    result.add(t.split(':')[0])
  for (k, root) in DirectoryRoots:
    for t in words(show.getOrDefault(k)):
      result.add(root & "/" & t.split(':')[0])

proc systemGid*(group: string): int =
  ## The gid ``getent group`` gives ``group``, -1 when it gives none.
  let exe = resolveHostTool(GetentCandidates)
  if exe.len == 0: return -1
  let r = runHostTool([exe, "group", "--", group], mergeStderr = false)
  if r.exitCode != 0: return -1
  let f = r.output.strip().split(':')
  if f.len < 3: return -1
  try: parseInt(f[2]) except ValueError: -1

proc systemUid*(name: string): int =
  ## The uid ``getent passwd`` gives ``name``, -1 when it gives none.
  let exe = resolveHostTool(GetentCandidates)
  if exe.len == 0: return -1
  let r = runHostTool([exe, "passwd", "--", name], mergeStderr = false)
  if r.exitCode != 0: return -1
  let f = r.output.strip().split(':')
  if f.len < 3: return -1
  try: parseInt(f[2]) except ValueError: -1

proc systemGroups*(name: string): seq[string] =
  ## The groups a static account is in: its primary group (``getent
  ## passwd``'s gid, named by ``getent group``; the number when no group
  ## has it, ``root`` for gid 0) and every group whose member list names it
  ## (``getent group``: /etc/group and NSS). An account getent does not
  ## know is reported in ``root``: refused rather than trusted.
  let exe = resolveHostTool(GetentCandidates)
  if exe.len == 0 or name.len == 0: return @["root"]
  let pw = runHostTool([exe, "passwd", "--", name], mergeStderr = false)
  if pw.exitCode != 0: return @["root"]
  let f = pw.output.strip().split(':')
  if f.len < 4: return @["root"]
  let all = runHostTool([exe, "group"], mergeStderr = false)
  if all.exitCode != 0: return @["root"]
  var primary = if f[3] == "0": "root" else: f[3]
  for l in all.output.splitLines():
    let g = l.split(':')
    if g.len < 4: continue
    if g[2] == f[3]: primary = g[0]
    elif name in g[3].split(','): result.add(g[0])
  result.insert(primary, 0)

proc systemUserOfUid*(uid: int): string =
  ## The name ``getent passwd`` gives ``uid``, "" when it gives none.
  let exe = resolveHostTool(GetentCandidates)
  if exe.len == 0 or uid < 0: return ""
  let r = runHostTool([exe, "passwd", "--", $uid], mergeStderr = false)
  if r.exitCode != 0: return ""
  r.output.strip().split(':')[0]

proc accountProblems*(user, group, supplementaryGroups, dynamicUser,
                      unit: string;
                      uidOf: proc (name: string): int;
                      groupsOf: proc (name: string): seq[string];
                      gidOf: proc (group: string): int;
                      userOfUid: proc (uid: int): string = systemUserOfUid):
                      seq[string] =
  ## Why the account ``unit`` runs with these settings (as ``systemctl
  ## show`` prints them) breaks the floor, one line each: it runs as uid 0,
  ## holds a privileged group (``PrivilegedGroups``, by gid), or does not
  ## resolve. The account is resolved by ``resolveServiceAccount`` over the
  ## account databases ``uidOf``, ``groupsOf`` (every group an account is
  ## in, its primary group first: ``systemGroups``) and ``gidOf`` -- the
  ## live host's, through getent, in a product build.
  ##
  ## Every group ``groupsOf`` names counts as held, the primary group as
  ## well even when ``Group=`` replaces it: a refusal more than systemd
  ## needs, never less.
  if dynamicUser == "yes" and mutated("dynamic-user-trusted"):
    # Falsifying build: round 5's reading, under which DynamicUser=yes
    # skipped the account rules whatever account systemd would use.
    return
  var names: seq[tuple[name: string; gid: int]]
  proc note(n: string; gid: int) =
    for x in names:
      if x.name == n: return
    names.add((n, gid))
  var lookup: AccountLookup
  lookup.uidOf = uidOf
  lookup.gidOf = proc (g: string): int =
    result = gidOf(g)
    note(g, result)
  lookup.primaryGidOf = proc (n: string): int =
    let gs = groupsOf(n)
    if gs.len == 0: return UnknownId
    result = (try: parseInt(gs[0]) except ValueError: gidOf(gs[0]))
    note(gs[0], result)
  lookup.groupsOf = proc (n: string): seq[int] =
    for g in groupsOf(n):
      let gid = (try: parseInt(g) except ValueError: gidOf(g))
      note(g, gid)
      result.add(gid)
  lookup.userOfUid = userOfUid
  # Answered by NSS (getent), as systemd asks it: a name it does not know
  # is no account, so DynamicUser=yes allocates one (service_account,
  # ``AccountLookup.authoritative``).
  lookup.authoritative = true
  let a = resolveServiceAccount(user, group, supplementaryGroups,
                                dynamicUser == "yes", unit, lookup)
  for u in a.unknown:
    result.add(u & ", which getent does not know or systemd cannot " &
               "resolve: refused, not taken for an unprivileged account")
  if a.uid == 0:
    result.add("runs as root (User=" & user & ", DynamicUser=" &
               dynamicUser & ")")
  var privileged = initHashSet[int]()
  privileged.incl(0)
  for n in PrivilegedGroups:
    let gid = (try: parseInt(n) except ValueError: gidOf(n))
    if gid >= 0: privileged.incl(gid)
  proc nameOf(gid: int): string =
    for x in names:
      if x.gid == gid: return x.name
    $gid
  let held = a.allGids
  when mutated("privileged-groups-by-name"):
    # Falsifying build (round 5, finding 4): round 4's rule, by name only
    # -- a second name for a privileged gid, and an unknown group, pass.
    for x in names:
      if x.gid in held and x.name in PrivilegedGroups:
        result.add("runs with the privileged group " & x.name)
    return
  var flagged = initHashSet[int]()
  for gid in held:
    if gid >= 0 and gid in privileged and gid notin flagged:
      flagged.incl(gid)
      result.add("runs with the privileged group " & nameOf(gid) &
                 " (gid " & $gid & ")")
  for x in names:
    if x.gid notin held: continue
    if x.gid == UnknownId:
      # A membership the resolver does not report (it reports what
      # User=, Group= and SupplementaryGroups= name).
      var told = false
      for u in a.unknown:
        if x.name in u: told = true
      if not told:
        result.add("runs with the group " & x.name &
                   ", which getent does not know")
    elif x.name in PrivilegedGroups and x.gid notin flagged:
      # A privileged group's name, whatever gid this host gives it.
      flagged.incl(x.gid)
      result.add("runs with the privileged group " & x.name)

proc limitValue*(v: string): uint64 =
  ## A ``Limit*`` value as systemd shows it; ``infinity`` is the largest.
  if v == "infinity" or v.len == 0: return high(uint64)
  try: uint64(parseBiggestUInt(v)) except ValueError: high(uint64)

proc ownedChainProblem(path: string): string =
  ## Why the directories above ``path`` are not all root-owned and closed
  ## to their group and others, or "".
  var d = parentDir(path)
  while d.len > 0:
    var ds: Stat
    if lstat(d.cstring, ds) != 0: return "its directory " & d & " cannot be read"
    if not S_ISDIR(ds.st_mode) and not S_ISLNK(ds.st_mode):
      return d & " is not a directory"
    if ds.st_uid != 0: return "its directory " & d & " is not owned by root"
    if not S_ISLNK(ds.st_mode) and (ds.st_mode.cint and 0o022) != 0:
      return "its directory " & d & " is writable by its group or others"
    if d == "/": break
    d = parentDir(d)
  ""

proc managerPathProblem*(path: string; uid: int; dynamic: bool): string =
  ## Why the service manager may not create ``path`` (a ``*Directory=`` or
  ## its link) for a unit running as ``uid`` (``dynamic``: a dynamic user),
  ## as the host is now, or "": it does not exist yet, or it is the unit's
  ## own -- owned by its static account, or, for a dynamic user, a dynamic
  ## id's or the manager's link into ``private/`` (systemd.exec(5),
  ## ``DynamicUser=``). An existing path of anyone else's -- ``/run/systemd``
  ## for ``RuntimeDirectory=systemd`` -- would be chowned to the service by
  ## the manager, as root (A9 review round 7, finding 2).
  var st: Stat
  if lstat(path.cstring, st) != 0: return ""
  let owner = int(st.st_uid)
  if not dynamic and uid > 0 and owner == uid: return ""
  if dynamic:
    if owner in 61184 .. 65519: return ""
    if S_ISLNK(st.st_mode) and owner == 0:
      try:
        if expandSymlink(path).startsWith("private/"): return ""
      except OSError: discard
  "it exists and belongs to uid " & $owner & ", not to the unit's own " &
    "account; the manager would hand it to the service"

proc ownedStorePath*(path: string; owned: openArray[string]): bool =
  ## ``path`` (normalised, no ``..``) lies inside one of the store objects
  ## ``owned``, compared by path component: ``/repro/store`` itself, and a
  ## store path in no owned object, are not.
  for o in owned:
    let r = normalisedPath(o)
    if path == r or path.startsWith(r & "/"): return true

proc withoutFloorBlock*(rendered: string): string =
  ## A rendered unit file without the floor's own block (``FloorMarker`` to
  ## the end of its ``[Service]`` section): the bytes the floor judged
  ## before appending it.
  var inBlock = false
  var lines: seq[string]
  for raw in rendered.split('\n'):
    let l = raw.strip()
    if l == FloorMarker:
      inBlock = true
      continue
    if inBlock and l.startsWith("[") and l.endsWith("]"): inBlock = false
    if not inBlock: lines.add(raw)
  lines.join("\n")

proc environmentFileProblem*(path: string; service = "";
                             owned: openArray[string] = [];
                             adopted = initTable[string, string]()): string =
  ## Why the manager may not read ``path`` as root for a floored service's
  ## ``EnvironmentFile=``, or "" (§13 decision 50; A9 review rounds 5-7).
  ## The whole path is resolved, every link in it followed; the file it
  ## resolves to must lie in one of the store objects ``owned`` (the
  ## generation's own, with a recorded digest), or under the service's own
  ## ``/run/repro/secrets/<service>/``. Anything else is refused whatever
  ## its owner or mode: with neither given, every path is. The link (the
  ## add-on materialises an /etc file as a link into the read-only store)
  ## and its directories, and the file and its directories, must also be
  ## root-owned and closed to group and others, so nothing could swap them.
  ## An error reading any of that refuses (default-deny).
  ##
  ## *Amended by the owner, 2026-11-06* (decision 50, third case): a file
  ## the generation adopts (``adopted``: path -> the sha256 the ledger
  ## records for it) is accepted where it is: a regular file, not a link,
  ## root-owned and closed to group and others under such directories,
  ## whose current bytes are exactly the ones adopted. An operator's edit
  ## since the adoption changes them, and the check refuses until the file
  ## is adopted again.
  var st: Stat
  if lstat(path.cstring, st) != 0: return "it does not exist (or cannot be read)"
  let np0 = normalisedPath(path)
  if np0 in adopted:
    if S_ISLNK(st.st_mode) or not S_ISREG(st.st_mode):
      return "the adopted file is not a regular file"
    if st.st_uid != 0: return "the adopted file is not owned by root"
    if (st.st_mode.cint and 0o022) != 0:
      return "the adopted file is writable by its group or others"
    let chain = ownedChainProblem(path)
    if chain.len > 0: return chain
    when not mutated("adopted-files-unverified"):
      var now = ""
      try: now = sha256OfFile(path)
      except IOError, OSError: return "the adopted file cannot be read"
      if now != adopted[np0]:
        return "the adopted file has changed since it was adopted (sha256 " &
          "now " & now & ", the ledger records " & adopted[np0] & "): the " &
          "manager would hand the service bytes no generation reviewed; " &
          "review the file and adopt it again with `repro system adopt " &
          "<its address> --profile <file>`"
    return ""
  var target = path
  when mutated("environment-file-links-refused"):
    # Falsifying build: round 5's lstat, which refused the add-on's own
    # /etc files (links into the store) as "not a regular file".
    if S_ISLNK(st.st_mode): return "it is not a regular file"
  if S_ISLNK(st.st_mode):
    when not mutated("environment-file-links-unchecked"):
      if st.st_uid != 0: return "the link is not owned by root"
      let why = ownedChainProblem(path)
      if why.len > 0: return why
  # Every link on the way, not only the last component.
  try: target = expandFilename(path)
  except OSError: return "the path cannot be resolved"
  if stat(target.cstring, st) != 0: return "its target " & target & " cannot be read"
  if not S_ISREG(st.st_mode): return "it is not a regular file"
  if st.st_uid != 0: return "it is not owned by root"
  if (st.st_mode.cint and 0o022) != 0: return "it is writable by its group or others"
  let chain = ownedChainProblem(target)
  if chain.len > 0: return chain
  when not mutated("environment-files-by-mode"):
    let rt = normalisedPath(target)
    if service.len > 0 and rt.startsWith(CredentialRoot & "/" & service & "/"):
      return ""
    if ownedStorePath(rt, owned): return ""
    return "it resolves to " & rt & ", which is neither in a store object " &
      "this generation owns nor under the service's own secrets directory" &
      (if service.len > 0: " (" & CredentialRoot & "/" & service & "/)" else: "") &
      "; the manager reads it as root and hands its contents to the service"
  ""

proc managerLimits*(): Table[string, string] =
  ## The service manager's ``DefaultLimit*`` (``systemctl show`` of the
  ## manager itself).
  let r = runSystemctl(["show", "--no-pager"])
  if r.exitCode != 0:
    raise newException(OSError, "systemctl show (the manager): " & r.output.strip())
  for k, v in parseShow(r.output):
    if k.startsWith("DefaultLimit"): result[k] = v

const
  ActivatorDefaults* = [
    ("Mark", @["-1"]), ("Transparent", @["no"]), ("BindToDevice", @[""]),
    ("FreeBind", @["no"]), ("PassSecurity", @["no"]), ("ReusePort", @["no"]),
    ("ReceiveBuffer", @["0"]), ("SendBuffer", @["0"]), ("TCPCongestion", @[""]),
    ("SmackLabel", @[""]), ("SmackLabelIPIn", @[""]), ("SmackLabelIPOut", @[""]),
    ("SELinuxContextFromNet", @["", "no"]), ("Symlinks", @[""]),
    ("Writable", @["no"]), ("PipeSize", @["0"]),
    ("MessageQueueMaxMessages", @["0"]), ("MessageQueueMessageSize", @["0"]),
    ("PassFileDescriptorsToExec", @["", "no"]), ("WakeSystem", @["", "no"]),
    ("MakeDirectory", @["", "no"]), ("AllowIsolate", @["", "no"]),
    ("OnFailureJobMode", @["", "replace", "fail"]),
    ("OnSuccessJobMode", @["", "replace", "fail"])]
    ## The reported value each refused option of an activator must have:
    ## its default, as ``systemctl show --all`` prints it on systemd 252,
    ## 255, 257 and 259 for a unit that does not set it
    ## (``tests/fixtures/systemd_properties/show-all-{socket,timer,path}-*``;
    ## A9 review round 7, findings 3 and 5). The socket options that need a
    ## capability (``Mark=``, ``Transparent=``, ``BindToDevice=``, the forced
    ## buffers, ``TCPCongestion=``), that act on paths (``Symlinks=``,
    ## ``MakeDirectory=``), that wake the host (``WakeSystem=``), and the job
    ## modes and isolation (finding 4).

proc activatorProblems*(unit: string; show: ShowProps; lines: ShowLines;
                        fragment: string; ownDropIns: openArray[string];
                        loaded: openArray[tuple[path, content: string]] = [];
                        startsOf: proc (u: string): seq[string] = nil):
                        seq[string] =
  ## A socket, timer or path unit that triggers a floored service, as
  ## systemd reads it (A9 review rounds 5 and 7): loaded from the add-on's
  ## file with only its drop-ins; no command line; each listener a stream,
  ## datagram or sequential-packet socket at an address the floor allows
  ## (``listenerRefusal``); each refused option at its default
  ## (``ActivatorDefaults``); ``Priority=`` 0-6; socket accounts not root; no
  ## system-state unit reached by any route; and the parse-time rules
  ## (``activatorRefusal``) applied again to the files it loaded. The other
  ## properties a socket reports are its execution context, used only by
  ## its command lines, which are refused here and in its files.
  template problem(s: string) = result.add(unit & ": " & s)
  if show.getOrDefault("FragmentPath") != fragment:
    problem("FragmentPath=" & show.getOrDefault("FragmentPath") &
            ", not a unit file the add-on wrote (" & fragment & ")")
  for d in words(show.getOrDefault("DropInPaths")):
    if d notin ownDropIns:
      problem("the drop-in " & d & " is not one the add-on installed")
  for k, v in show:
    if k.startsWith("Exec") and not k.startsWith("ExecMain") and v.len > 0:
      problem(k & " runs a command as root")
  for l in lines.getOrDefault("Listen"):
    let open = l.rfind('(')
    let kind = if open >= 0: l[open + 1 .. ^1].strip(chars = {')', ' '}) else: ""
    if kind notin ["Stream", "Datagram", "SequentialPacket"]:
      problem("listener " & l & " is opened as root and handed to the service")
      continue
    when not mutated("activator-show-unjudged"):
      let address = (if open >= 0: l[0 ..< open] else: l).strip()
      let why = listenerRefusal(unit, address)
      if why.len > 0: problem("listener " & l & ": " & why)
  when not mutated("activator-show-unjudged"):
    for (k, allowed) in ActivatorDefaults:
      if k in show and show[k] notin allowed:
        problem(k & "=" & show[k] & " is refused on a unit that activates " &
                "a floored service (only " & allowed.join(" or ") & ")")
    if "Priority" in show:
      let n = (try: parseInt(show["Priority"]) except ValueError: 99)
      if n != -1 and n notin 0 .. 6:
        problem("Priority=" & show["Priority"] & " needs CAP_NET_ADMIN (0-6 only)")
    for k in ["SocketUser", "SocketGroup"]:
      if show.getOrDefault(k) in ["root", "0"]:
        problem(k & "=" & show[k] & " (the floor allows only a non-root account)")
    let route = systemStateRoute([unit], proc (u: string): seq[string] =
      if u == unit:
        for k in StartingDependencyKeys: result.add(words(show.getOrDefault(k)))
        result.add(words(show.getOrDefault("Triggers")))
      elif startsOf != nil:
        result = startsOf(u))
    if route.len > 0:
      problem("starts " & route[^1] & " (" & route.join(" -> ") &
              "), which changes the whole system's state")
    for (path, content) in loaded:
      let why = activatorRefusal(unit, content, dropIn = path != fragment,
                                 half = fhEffective)
      if why.len > 0: problem(path & ", by the floor's rules: " & why)

type
  EffectiveInput* = object
    ## What the check compares: the unit as systemd reports it, and what
    ## the generation installed for it.
    unit*: string             ## the unit (an instance, for a template)
    rendered*: string         ## the unit file the generation wrote
    version*: string          ## the floor version it was rendered under
    exceptions*: seq[string]  ## its ``floorExceptions``
    show*: ShowProps          ## ``systemctl show``, last line per key
    lines*: ShowLines         ## ``systemctl show``, every line per key
    fragment*: string         ## the unit file systemd must load it from
    ownDropIns*: seq[tuple[path, content: string]]
      ## the drop-ins the generation installed for it (and the start
      ## hold), with their bytes
    loaded*: seq[tuple[path, content: string]]
      ## the files systemd says it loaded (``FragmentPath``,
      ## ``DropInPaths``), with their bytes as read now
    denied*: HashSet[string]  ## the calls the floor's deny line names
    uidOf*: proc (name: string): int
    groupsOf*: proc (name: string): seq[string]
    inspectFile*: proc (path: string): string
      ## why the manager may not read ``path`` as root for the service (an
      ## ``EnvironmentFile=``), "" when it may (``environmentFileProblem``)
    gidOf*: proc (group: string): int
      ## a group's gid, -1 when unknown (``systemGid``)
    otherWritable*: seq[string]
      ## the writable places of every other floored unit of the generation
    ownUnits*: HashSet[string]
      ## the units the generation installs (``Sockets=`` may name only these)
    partialShow*: bool
      ## ``show`` is a hand-written excerpt (unit tests), not ``systemctl
      ## show --all``: ``RequiredProps`` are not all expected. The floor's
      ## own settings must be there either way.
    limitCeilings*: Table[string, string]
      ## the manager's ``DefaultLimit<X>`` per ``Limit<X>`` (``managerLimits``)
    storeObjects*: seq[string]
      ## the store objects the generation owns and has a recorded digest
      ## for (§13 decisions 46 and 48); when empty, the unit's own closure
      ## (``referencedStoreObjects`` of its rendering)
    ownFiles*: seq[string]
      ## the ``fs.systemFile`` paths the generation installs (as links into
      ## its store)
    adoptedFiles*: Table[string, string]
      ## the ``fs.systemFile`` paths the generation adopts (``collision =
      ## adopt``), each with the sha256 its ledger records
    startsOf*: proc (unit: string): seq[string]
      ## what another unit starts, as systemd reports it (``nil``: only the
      ## unit's own dependencies are followed)
    inspectPath*: proc (path: string; uid: int; dynamic: bool): string
      ## why the manager may not create ``path`` for the unit, as it is on
      ## the host now (``managerPathProblem``)

proc expectedCommands*(files: openArray[string]; key: string): seq[string] =
  ## The executables ``key`` runs when systemd reads ``files`` in order (a
  ## unit file, then its drop-ins): each assignment adds its commands, an
  ## empty one resets the list (systemd.service(5)).
  for content in files:
    for d in sectionDirectives(content, ["Service"]):
      if d.key != key: continue
      if d.value.strip().len == 0:
        result.setLen(0)
        continue
      for c in commands(d.value): result.add(c.path)

proc effectiveFloorProblems*(e: EffectiveInput): seq[string] =
  ## Where ``unit``'s effective configuration (``show``) does not hold the
  ## floor it was rendered under (``rendered``, ``version``, minus
  ## ``exceptions``): one line each, empty when it holds. ``ownDropIns``
  ## are the drop-ins the add-on installed for it, ``denied`` the calls the
  ## floor's deny line names (expanded, add-backs removed), ``uidOf`` an
  ## account's uid (-1 when unknown), ``groupsOf`` the names of every group
  ## a static account is in (its primary group first; ``systemGroups``).
  let (unit, rendered, version, show) = (e.unit, e.rendered, e.version, e.show)
  let exceptions = e.exceptions
  let denied = e.denied
  let fb = floorBlock(rendered)
  let owned = if e.storeObjects.len > 0: e.storeObjects
              else: referencedStoreObjects(rendered)
  let ex = exceptionKeys(exceptions)
  let v = versionNumber(version)
  var ownDropIns: seq[string]
  for d in e.ownDropIns: ownDropIns.add(d.path)
  template problem(s: string) = result.add(unit & ": " & s)
  if show.getOrDefault("LoadState") != "loaded":
    problem("LoadState=" & show.getOrDefault("LoadState") & ", not loaded")
  for k in ScalarFloorKeys:
    if k in fb:
      let want = fb[k][^1]
      if show.getOrDefault(k) != want:
        problem(k & "=" & show.getOrDefault(k) & ", the floor's is " & want)
  for k in ["CapabilityBoundingSet", "AmbientCapabilities"]:
    if k in fb:
      var want, got: HashSet[string]
      for t in words(fb[k][^1]): want.incl(t.toLowerAscii())
      for t in words(show.getOrDefault(k)): got.incl(t.toLowerAscii())
      if want != got:
        problem(k & "=" & show.getOrDefault(k) & ", the floor's is " &
                fb[k][^1])
  if "RestrictAddressFamilies" in fb:
    var want, got: HashSet[string]
    for t in words(fb["RestrictAddressFamilies"][^1]): want.incl(t)
    for t in words(show.getOrDefault("RestrictAddressFamilies")): got.incl(t)
    if want != got:
      problem("RestrictAddressFamilies=" &
        show.getOrDefault("RestrictAddressFamilies") & ", the floor's is " &
        fb["RestrictAddressFamilies"][^1])
  if "DynamicUser" in fb and show.getOrDefault("DynamicUser") != "yes":
    problem("DynamicUser=" & show.getOrDefault("DynamicUser") &
            ", the floor's is yes")
  let noExec = pathSet(show.getOrDefault("NoExecPaths"))
  if "NoExecPaths" in fb:
    for line in fb["NoExecPaths"]:
      for p in pathSet(line):
        if p notin noExec:
          problem("NoExecPaths= lacks " & p & ", which the floor names")
  let execPaths = pathSet(show.getOrDefault("ExecPaths"))
  if "ExecPaths" in fb:
    var want: HashSet[string]
    for line in fb["ExecPaths"]:
      for p in pathSet(line): want.incl(p)
    if want != execPaths:
      problem("ExecPaths=" & show.getOrDefault("ExecPaths") &
              ", the floor's is " & fb["ExecPaths"].join(" "))
  elif "NoExecPaths" in fb and execPaths.len > 0:
    problem("ExecPaths=" & show.getOrDefault("ExecPaths") &
            ", the floor renders none")
  if "ReadOnlyPaths" in fb:
    let ro = pathSet(show.getOrDefault("ReadOnlyPaths"))
    for line in fb["ReadOnlyPaths"]:
      for p in pathSet(line):
        if p notin ro: problem("ReadOnlyPaths= lacks " & p)
  if "SystemCallFilter" in fb:
    let f = show.getOrDefault("SystemCallFilter")
    if f.startsWith("~"):
      problem("SystemCallFilter is a deny list, the floor's an allow list")
    else:
      var bad: seq[string]
      for t in words(f):
        if t in denied: bad.add(t)
      if bad.len > 0:
        bad.sort()
        problem("SystemCallFilter allows " & bad.join(" ") &
                ", which the floor denies")
  # Provenance (A9 review round 4, finding 3): the unit is loaded from the
  # file the generation wrote, with exactly the drop-ins it installed --
  # a vendor drop-in under /usr/lib/systemd, a type-wide service.d/ or a
  # prefix drop-in included -- so everything systemd reports below comes
  # from bytes the generation wrote.
  when not mutated("dropins-from-the-distribution-trusted"):
    for d in words(show.getOrDefault("DropInPaths")):
      if d notin ownDropIns:
        problem("the drop-in " & d & " is not one the add-on installed")
  else:
    for d in words(show.getOrDefault("DropInPaths")):
      if d notin ownDropIns and not d.startsWith("/usr/lib/systemd/") and
          not d.startsWith("/lib/systemd/"):
        problem("the drop-in " & d & " is not one the add-on installed")
  if e.fragment.len > 0 and show.getOrDefault("FragmentPath") != e.fragment:
    problem("FragmentPath=" & show.getOrDefault("FragmentPath") &
            ", not the unit file the add-on wrote (" & e.fragment & ")")
  if show.getOrDefault("SourcePath").len > 0:
    problem("SourcePath=" & show.getOrDefault("SourcePath") &
            ": generated from another file")
  if v >= 2:
    # Root is refused whatever the unit's exceptions (A9 review round 4,
    # finding 4: a User= or DynamicUser= exception lifts the account's
    # spelling rules, never uid 0), and so is every privileged group the
    # service runs with (round 4, finding 1; by gid, round 5, finding 4).
    #
    # The account is the one systemd will use (A9 review round 6, finding
    # 1), resolved by the shared resolver (``service_account``) over the
    # live host's account databases: specifiers expanded, a static account
    # of the configured name winning over DynamicUser=yes for the user and
    # the group, a second name for uid 0 being root, and the user's
    # /etc/group memberships held. Whatever does not resolve is refused.
    for p in accountProblems(show.getOrDefault("User"),
        show.getOrDefault("Group"), show.getOrDefault("SupplementaryGroups"),
        show.getOrDefault("DynamicUser"), unit,
        (if e.uidOf != nil: e.uidOf else: systemUid),
        (if e.groupsOf != nil: e.groupsOf else: systemGroups),
        (if e.gidOf != nil: e.gidOf else: systemGid)):
      problem(p)
    if "RootDirectory" notin ex:
      for k in ["RootDirectory", "RootImage"]:
        if show.getOrDefault(k).len > 0:
          problem(k & "=" & show.getOrDefault(k))
  if v >= 4:
    if show.getOrDefault("PAMName").len > 0:
      problem("PAMName=" & show.getOrDefault("PAMName"))
    for k in ["MountImages", "ExtensionImages", "ExtensionDirectories"]:
      if k notin ex and show.getOrDefault(k).len > 0:
        problem(k & "=" & show.getOrDefault(k))
    if ExecConfinementException notin ex:
      for w in writablePlaces(show):
        let p = normalisedPath(w)
        for kt in KernelTrees:
          if p == kt or p.startsWith(kt & "/") or kt.startsWith(p & "/"):
            problem("the writable place " & p & " is in or over " & kt)
        if p notin noExec:
          problem("the writable place " & p & " is not in NoExecPaths=")
        for x in execPaths:
          if p == x or p.startsWith(x & "/") or x.startsWith(p & "/"):
            problem("the writable place " & p & " overlaps ExecPaths= " & x)

  # Default-deny over everything systemd reports (A9 review round 4,
  # finding 3): each property is compared with the floor, is a command
  # compared with the generation's own rendering, or is reviewed as inert.
  when not mutated("properties-not-default-denied"):
    for k, val in show:
      if k in FileJudgedProps:
        # Judged from the loaded files because systemd prints it as
        # [unprintable] or not at all; a systemd that prints a value has not
        # been reviewed (round 7: a printed Sockets= was accepted unjudged).
        if val in ["", "[unprintable]"] or mutated("printed-file-settings-trusted"):
          continue
        problem("the property " & k & "=" & val & " is one the floor reads " &
                "from the loaded files; this systemd prints it, which is " &
                "not reviewed; refused")
        continue
      if k in ComparedProps or k in LimitProps or
          isExecProp(k) or isInertProp(k): continue
      problem("the property " & k & "=" & val & " is neither compared " &
              "with the floor nor reviewed as inert; refused")
    # The commands, from the Ex forms (which carry the flags).
    var files = @[rendered]
    for d in e.ownDropIns: files.add(d.content)
    var execRoots: seq[string]
    for line in fb.getOrDefault("ExecPaths"):
      for q in pathSet(line): execRoots.add(q)
    for k in ExecProps:
      let got = execEntries(e.lines, k)
      let want = expectedCommands(files, k)
      if got.len != want.len:
        problem(k & " runs " & $got.len & " command(s), the generation's " &
                "rendering " & $want.len)
      for i, c in got:
        for f in c.flags:
          if f notin AllowedExecFlags:
            problem(k & " " & c.path & " carries the flag " & f &
                    " (it runs outside the user or the sandbox)")
        if i < want.len and want[i].startsWith("/") and
            normalisedPath(want[i]) != normalisedPath(c.path):
          problem(k & " runs " & c.path & ", the rendering " & want[i])
        if "NoExecPaths" in fb and ExecConfinementException notin ex:
          let cp = normalisedPath(c.path)
          var inside = false
          for r in execRoots:
            if cp == r or cp.startsWith(r & "/"): inside = true
          if not inside:
            problem(k & " runs " & c.path & ", outside ExecPaths=")
    # The files systemd opens for the service, as root, before the sandbox.
    if show.getOrDefault("OpenFile").len > 0:
      problem("OpenFile=" & show["OpenFile"] & " opens a file as root")
    let sin = show.getOrDefault("StandardInput")
    if sin.len > 0 and sin notin AllowedStdin:
      problem("StandardInput=" & sin & " opens a file or terminal")
    for k in ["StandardOutput", "StandardError"]:
      let so = show.getOrDefault(k)
      if so.len > 0 and so notin AllowedStdout:
        problem(k & "=" & so & " opens a file or terminal")
    if show.getOrDefault("TTYPath").len > 0:
      problem("TTYPath=" & show["TTYPath"])
    if show.getOrDefault("SecureBits") notin ["", "0"]:
      problem("SecureBits=" & show["SecureBits"])
    if show.getOrDefault("KeyringMode") notin ["", "private"]:
      problem("KeyringMode=" & show["KeyringMode"] & ", not private")
    for k in ["Personality", "JoinsNamespaceOf", "NetworkNamespacePath",
              "IPCNamespacePath", "BPFProgram", "USBFunctionDescriptors",
              "USBFunctionStrings", "ExecSearchPath", "RootHash",
              "RootHashSignature", "RootVerity", "RootHashPath",
              "RootHashSignaturePath",
              "UserNamespacePath", "SELinuxContext",
              "AccessSELinuxContext", "AppArmorProfile", "SmackProcessLabel",
              "BPFDelegateCommands", "BPFDelegateMaps", "BPFDelegatePrograms",
              "BPFDelegateAttachments"]:
      if show.getOrDefault(k).len > 0:
        problem(k & "=" & show[k])
    for k in ["RootDirectoryStartOnly", "Delegate", "CoredumpReceive",
              "RootEphemeral", "Transient"]:
      if show.getOrDefault(k) notin ["", "no"]:
        problem(k & "=" & show[k])
    if show.getOrDefault("MountFlags") notin ["", "0"]:
      problem("MountFlags=" & show["MountFlags"] & " (mount propagation)")
    # A ``*Directory=`` entry is shown again with its symlinks
    # (``name:link``, systemd 254+): each link stays inside the directory
    # root, under a name without ``/`` or ``..``.
    for (k, _) in DirectoryRoots:
      for t in words(show.getOrDefault(k & "Symlink")):
        let c = t.find(':')
        let link = if c >= 0: t[c + 1 .. ^1] else: ""
        if link.len > 0 and (link.startsWith("/") or hasDotDot(link)):
          problem(k & "Symlink=" & t & ": a link outside the directory root")
        elif link.len > 0 and '/' in link and not mutated("manager-paths-unchecked"):
          # Round 7, finding 2: a link of more than one name is created by
          # the manager, as root, inside a tree other software reads.
          problem(k & "Symlink=" & t & ": a directory's link is one name")
    # The paths the manager creates for the unit, as root (A9 review round
    # 7, finding 2): none in the add-on's own trees -- where its start hold
    # and its decisions live -- and none that already exists and belongs to
    # someone else, which the manager would hand over to the service.
    when not mutated("manager-paths-unchecked"):
      var created: seq[tuple[key, path: string]]
      for (k, root) in DirectoryRoots:
        for t in words(show.getOrDefault(k)):
          created.add((k, normalisedPath(root & "/" & t.split(':')[0])))
        for t in words(show.getOrDefault(k & "Symlink")):
          let c = t.find(':')
          if c >= 0 and t[c + 1 .. ^1].len > 0 and not t[c + 1 .. ^1].startsWith("/"):
            created.add((k & "Symlink", normalisedPath(root & "/" & t[c + 1 .. ^1])))
      let dynamic = show.getOrDefault("DynamicUser") == "yes"
      let user = show.getOrDefault("User")
      let uid = if user.len > 0 and e.uidOf != nil: e.uidOf(user) else: -1
      for (k, p) in created:
        if inAddOnTree(p):
          problem(k & " creates " & p & ", in the add-on's own tree")
          continue
        let why = (if e.inspectPath != nil: e.inspectPath(p, uid, dynamic)
                   else: managerPathProblem(p, uid, dynamic))
        if why.len > 0: problem(k & " " & p & ": " & why)
    if show.getOrDefault("DeviceAllow").len > 0 and
        show.getOrDefault("PrivateDevices") != "yes":
      problem("DeviceAllow=" & show["DeviceAllow"] & " without PrivateDevices=yes")
    let svc = unit[0 ..< max(0, unit.rfind('.'))]
    # The settings systemd shows as [unprintable], from the files it
    # loaded (round 6, finding 4).
    when not mutated("file-only-settings-unread"):
      for (path, content) in e.loaded:
        for d in sectionDirectives(content, ["Service"]):
          case d.key
          of "LoadCredential", "LoadCredentialEncrypted":
            let c = d.value.find(':')
            let src = if c >= 0: d.value[c + 1 .. ^1].strip() else: ""
            if src.startsWith("/") and
                not normalisedPath(src).startsWith(CredentialRoot & "/" & svc & "/"):
              problem(d.key & " reads " & src & ", outside the service's " &
                      "own credentials (" & CredentialRoot & "/" & svc & ")")
          of "Sockets":
            for t in d.value.splitWhitespace():
              if t notin e.ownUnits:
                problem("Sockets=" & t & " is not a socket unit the add-on installed")
          of "ImportCredential", "NFTSet", "RootImageOptions":
            if d.value.strip().len > 0:
              problem(d.key & "=" & d.value & " (in " & path & ")")
          else: discard
    # A compared property every supported systemd prints must be there
    # (round 6, finding 3): its absence is not a pass.
    when not mutated("absent-property-passes"):
      for k, _ in fb:
        if k notin show:
          problem("the floor's " & k & " is missing from systemctl show")
      if not e.partialShow:
        for k in RequiredProps:
          if k notin show:
            problem("the property " & k & " is missing from systemctl show")
    # A read-only bind over the executable paths replaces what may run
    # (round 6, finding 4): only a store object's own tree may be bound
    # there (the apt closure's /usr).
    when not mutated("read-only-binds-unjudged"):
      for t in words(show.getOrDefault("BindReadOnlyPaths")):
        let parts = t.strip(leading = true, trailing = false,
                            chars = {'-', '+'}).split(':')
        if parts.len < 2: continue
        # A source in a store object the generation owns, compared by path
        # component after systemd's normalisation; a `..` is refused, since
        # systemd resolves it on the file system, not lexically (round 7,
        # finding 5).
        if hasDotDot(parts[0]):
          problem("BindReadOnlyPaths=" & t & ": a source with `..` is " &
                  "resolved by systemd at run time; refused")
          continue
        let src = normalisedPath(parts[0])
        let dst = normalisedPath(parts[1])
        when mutated("bind-sources-by-prefix"):
          if src.startsWith("/repro/store/"): continue
        else:
          if ownedStorePath(src, owned): continue
        for x in execPaths:
          if dst == x or dst.startsWith(x & "/") or x.startsWith(dst & "/"):
            problem("BindReadOnlyPaths=" & t & " binds " & src &
                    " over the executable path " & x)
    # EnvironmentFile= (round 5, finding 1): read by the manager as root, so
    # named exactly, existing, root-owned under root-owned parents nothing
    # but root can write, and outside every floored unit's writable place.
    var places: seq[string]
    for w in writablePlaces(show): places.add(normalisedPath(w))
    for w in e.otherWritable: places.add(normalisedPath(w))
    for t in words(show.getOrDefault("EnvironmentFiles")):
      when mutated("environment-files-trusted"): break
      if not t.startsWith("/"): continue
      let np = normalisedPath(t)
      if t.anyIt(it in {'*', '?', '['}):
        problem("EnvironmentFile " & t & " is a wildcard the manager expands as root")
        continue
      # Default-deny by its form (§13 decision 50): a store path, a file the
      # generation installs, or the service's own secrets.
      let form = environmentFileRefusal(unit, t, e.ownFiles)
      if form.len > 0:
        problem("EnvironmentFile " & t & ": " & form)
        continue
      for w in places:
        if np == w or np.startsWith(w & "/"):
          problem("EnvironmentFile " & np & " lies in the writable place " & w)
      # And by where it resolves, every link followed.
      let why = (if e.inspectFile != nil: e.inspectFile(np)
                 else: environmentFileProblem(np, credentialServiceOf(unit), owned,
                                              e.adoptedFiles))
      if why.len > 0: problem("EnvironmentFile " & np & ": " & why)
    # Sockets= names only profile sockets (round 5, finding 2), read from
    # the loaded files: systemctl show never prints it (round 6, finding 4).
    # Realtime scheduling under RestrictRealtime= (finding 3).
    if "RestrictRealtime" in fb and "RestrictRealtime" notin ex:
      if show.getOrDefault("CPUSchedulingPolicy") in ["1", "2", "fifo", "rr"]:
        problem("CPUSchedulingPolicy=" & show["CPUSchedulingPolicy"] &
                " is realtime, which RestrictRealtime=yes forbids")
      if show.getOrDefault("IOSchedulingClass") in ["1", "realtime"]:
        problem("IOSchedulingClass=" & show["IOSchedulingClass"] &
                " is realtime, which RestrictRealtime=yes forbids")
    # A system-state unit reached by any route (§13 decision 49; round 7,
    # finding 4): the unit's own starting dependencies, then what each
    # reached unit starts as systemd reports it (``startsOf``).
    when not mutated("state-targets-allowed"):
      let starts = e.startsOf
      let route = systemStateRoute([unit], proc (u: string): seq[string] =
        if u == unit:
          for k in StartingDependencyKeys: result.add(words(show.getOrDefault(k)))
        elif starts != nil:
          result = starts(u))
      if route.len > 0:
        problem("starts " & route[^1] & " (" & route.join(" -> ") &
                "), which changes the whole system's state")
    for k in ["OnFailureJobMode", "OnSuccessJobMode"]:
      if show.getOrDefault(k) notin ["", "replace", "fail"]:
        problem(k & "=" & show[k] & " changes the system's state beyond " &
                "the unit (only replace or fail)")
    if show.getOrDefault("AllowIsolate") notin ["", "no"]:
      problem("AllowIsolate=" & show["AllowIsolate"] & " lets a job stop " &
              "every unit the target does not want")
    for k in ["FailureAction", "SuccessAction", "StartLimitAction",
              "JobTimeoutAction"]:
      if show.getOrDefault(k) notin ["", "none"]:
        problem(k & "=" & show[k] & " (the floor allows only none)")
    for k in LimitProps:
      if k notin show: continue
      let base = if k.endsWith("Soft"): k[0 ..< k.len - 4] else: k
      let ceilKey = "Default" & base & (if k.endsWith("Soft"): "Soft" else: "")
      let ceil = e.limitCeilings.getOrDefault(ceilKey)
      if ceil.len == 0:
        problem(k & "=" & show[k] & ": no manager default to compare with")
      elif limitValue(show[k]) > limitValue(ceil):
        problem(k & "=" & show[k] & " raises the manager's default " & ceil)
    # The settings systemd does not report back (PermissionsStartOnly= is
    # applied at exec time and has no property): the files it loaded may
    # carry only keys the floor knows.
    for (path, content) in e.loaded:
      if path.endsWith("/" & StartHoldName): continue   # the switch's own hold
      let dropIn = path != e.fragment
      for d in sectionDirectives(content):
        if not floorKnowsKey(d.section, d.key, dropIn):
          problem(path & " sets " & d.key & "=, which the floor does not " &
                  "know (it is refused as systemd would not report it)")
  # Every rule of the parse-time half, applied again to the files systemd
  # loaded (A9 review round 7, finding 5): the effective-unit check is the
  # authority, so a rule enforced only at parse time is enforced here too,
  # on the same functions (``service_floor``, ``fhEffective``). The
  # fragment is judged without the floor's own block, exactly as the floor
  # judged the unit before appending it; each drop-in as a drop-in.
  if v >= 4:
    when not mutated("effective-skips-parse-rules"):
      var exParsed: seq[FloorException]
      try: exParsed = parseFloorExceptions(unit, exceptions)
      except EServiceFloor as x: problem(x.msg)
      var own = ""
      for (path, content) in e.loaded:
        if path == e.fragment or (e.fragment.len == 0 and own.len == 0):
          own = withoutFloorBlock(content)
      if own.len > 0:
        try:
          for why in [allowlistRefusal(unit, own, exParsed, dropIn = false,
                                       half = fhEffective),
                      floorRefusal(unit, serviceDirectives(own), exParsed,
                                   floorExecPaths(unit, own, exParsed),
                                   dropIn = false, half = fhEffective)]:
            if why.len > 0: problem("by the floor's rules: " & why)
        except EServiceFloor as x: problem("by the floor's rules: " & x.msg)
        for (path, content) in e.loaded:
          if path == e.fragment or path.endsWith("/" & StartHoldName): continue
          try:
            let why = dropInFloorRefusal(unit, own, content, exParsed,
                                         half = fhEffective)
            if why.len > 0: problem(path & ", by the floor's rules: " & why)
          except EServiceFloor as x: problem(path & ": " & x.msg)

# ---------------------------------------------------------------------------
# The deny line, expanded with the base's own systemd.
# ---------------------------------------------------------------------------

proc withoutEscapes(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\e' and i + 1 < s.len and s[i + 1] == '[':
      var j = i + 2
      while j < s.len and s[j] notin {'A'..'Z', 'a'..'z'}: inc j
      i = j + 1
    else:
      result.add(s[i])
      inc i

proc parseSyscallGroups*(text: string): Table[string, seq[string]] =
  ## ``systemd-analyze syscall-filter`` (escape sequences removed: systemd
  ## 255 writes one before each nested group even with no terminal).
  var cur = ""
  for raw0 in text.splitLines():
    let raw = withoutEscapes(raw0)
    let l = raw.strip()
    if l.len == 0 or l.startsWith("#"): continue
    if not raw.startsWith(" ") and l.startsWith("@"):
      cur = l
      result[cur] = @[]
    elif cur.len > 0:
      result[cur].add(l)

proc expandCalls*(groups: Table[string, seq[string]];
                  items: openArray[string]): HashSet[string] =
  proc go(item: string; acc: var HashSet[string]) =
    if item.startsWith("@"):
      if item in groups:
        for m in groups[item]: go(m, acc)
    else: acc.incl(item)
  for i in items: go(i, result)

proc deniedCalls*(rendered: string;
                  groups: Table[string, seq[string]]): HashSet[string] =
  ## The calls the floor block's ``~`` line denies, less what a later
  ## ``SystemCallFilter=`` line (an exception's add-back) allows again.
  let fb = floorBlock(rendered)
  if "SystemCallFilter" notin fb: return
  var deny, back: seq[string]
  var seenDeny = false
  for line in fb["SystemCallFilter"]:
    if line.startsWith("~"):
      seenDeny = true
      deny.add(words(line[1 .. ^1]))
    elif seenDeny:
      back.add(words(line))
  result = expandCalls(groups, deny) - expandCalls(groups, back)

proc baseSyscallGroups*(): Table[string, seq[string]] =
  ## The base's own syscall groups, from its ``systemd-analyze`` (by
  ## absolute path; ``host_exec``).
  let exe = resolveHostTool(SystemdAnalyzeCandidates)
  if exe.len == 0:
    raise newException(HostToolMissing, "systemd-analyze not found at " &
                       SystemdAnalyzeCandidates.join(" or "))
  let r = runHostTool([exe, "syscall-filter", "--no-pager"])
  if r.exitCode != 0:
    raise newException(OSError, "systemd-analyze syscall-filter: " &
                       r.output.strip())
  parseSyscallGroups(r.output)


