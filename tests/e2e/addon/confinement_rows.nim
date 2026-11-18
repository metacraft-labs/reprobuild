## The table the confinement gate runs (ReproOS Add-On Mode spec §10.1,
## CONF-4; threat model G55; owner decision 2026-11-18): for each setting
## of an add-on unit, a behavioural probe that the setting alone blocks,
## the other layers that would block the same probe (disabled for that
## row, as MS-2 and Validation-Criteria §"Deployment Hardening" require),
## and the lines that remove the setting.
##
## A row runs twice in a copy of the unit (``probeUnitCopy``): HELD (the
## other layers disabled, the setting as installed) must block the probe,
## and REMOVED (the setting removed too) must let it through. HELD proves
## the setting holds on its own; REMOVED proves the probe sees it -- the
## falsifier of that setting, recorded red then green per row.
##
## Pure: no I/O. ``t_addon_confinement_probe_never_ships`` checks the copy
## and the table; ``t_e2e_addon_confinement_settings_each_hold`` runs them.

import std/strutils

type
  Expect* = enum
    ## How HELD and REMOVED are read from the probe's line.
    exBlocked     ## HELD: the call failed (any errno) or the filter killed
                  ## the probe; REMOVED: the call succeeded.
    exErrnoNumber ## HELD: the call failed with EPERM (1); REMOVED: the
                  ## filter killed the probe (no line, a signal).
    exFilter      ## HELD: EPERM; REMOVED: the call reached the kernel (it
                  ## succeeded, or failed with another errno).

  ProbeRow* = object
    name*: string        ## the row's id in the record
    setting*: string     ## the key it falsifies; the row applies to a unit
                         ## whose ``[Service]`` sets it
    probe*: string       ## the probe's first argument
    arg*: string         ## its second ("$GW", "$DISK" are filled in)
    held*: seq[string]   ## lines that disable the other layers
    removed*: seq[string] ## lines that remove the setting
    rootOnly*: bool      ## the probe means nothing in an unprivileged unit
    amd64Only*: bool
    expect*: Expect
    impliedBy*: seq[string] ## keys that imply the setting, which the row
                            ## cannot remove: a unit setting one is skipped
    unlessValueHas*: string ## a unit whose value of the key contains this
                            ## allows what the probe tries, by design

const
  ProbePath* = "/usr/local/lib/a9probe/a9_confinement_probe"
    ## Where the gate installs the probe in the guest; never in a unit the
    ## add-on renders.
  ProbeOutDir* = "/run/a9probe-out"
  FilterReset = "SystemCallFilter="
  # ProtectClock= and ProtectKernelLogs= restrict the device cgroup too,
  # which hides the same devices PrivateDevices= does.
  DevicesOpen = @["PrivateDevices=no", "DevicePolicy=auto", "DeviceAllow=",
                  "ProtectClock=no"]

let ProbeRows*: seq[ProbeRow] = @[
  ProbeRow(name: "no-new-privileges", setting: "NoNewPrivileges", probe: "nnp",
    # CAP_CHOWN and CAP_FOWNER make the setuid copy; CAP_SYS_ADMIN keeps
    # systemd from implying NoNewPrivileges= through the unit's other
    # settings (systemd.exec(5), "NoNewPrivileges="), which would hide the
    # removal.
    held: @["RestrictSUIDSGID=no", "ReadWritePaths=/var/lib/a9probe",
            "CapabilityBoundingSet=CAP_CHOWN CAP_FOWNER CAP_SYS_ADMIN"],
    removed: @["NoNewPrivileges=no"],
    rootOnly: true),
  ProbeRow(name: "capability-bounding-set", setting: "CapabilityBoundingSet",
    probe: "caps", held: @[FilterReset],
    removed: @["CapabilityBoundingSet=CAP_SYS_CHROOT"], rootOnly: true),
  ProbeRow(name: "protect-system", setting: "ProtectSystem",
    probe: "protect-system", removed: @["ProtectSystem=no"], rootOnly: true),
  ProbeRow(name: "protect-home", setting: "ProtectHome", probe: "exists",
    arg: "/root/a9probe-marker", removed: @["ProtectHome=no"], rootOnly: true),
  ProbeRow(name: "private-tmp", setting: "PrivateTmp", probe: "exists",
    arg: "/tmp/a9probe-marker", removed: @["PrivateTmp=no"],
    impliedBy: @["DynamicUser"]),
  ProbeRow(name: "private-devices", setting: "PrivateDevices", probe: "exists",
    arg: "$DISK", held: @["DevicePolicy=auto", "DeviceAllow=", "ProtectClock=no",
    "ProtectKernelLogs=no"], removed: @["PrivateDevices=no"], rootOnly: true),
  ProbeRow(name: "protect-kernel-tunables", setting: "ProtectKernelTunables",
    probe: "kernel-tunables", held: @["ProcSubset=all", "ProtectProc=default"],
    removed: @["ProtectKernelTunables=no"],
    rootOnly: true),
  ProbeRow(name: "protect-kernel-modules", setting: "ProtectKernelModules",
    probe: "kernel-modules", removed: @["ProtectKernelModules=no"]),
  ProbeRow(name: "protect-kernel-logs", setting: "ProtectKernelLogs",
    probe: "kernel-logs", held: DevicesOpen,
    removed: @["ProtectKernelLogs=no"], rootOnly: true),
  ProbeRow(name: "protect-control-groups", setting: "ProtectControlGroups",
    probe: "control-groups",
    held: @["CapabilityBoundingSet=CAP_SYS_ADMIN CAP_DAC_OVERRIDE"],
    removed: @["ProtectControlGroups=no"],
    rootOnly: true),
  ProbeRow(name: "protect-clock", setting: "ProtectClock", probe: "clock",
    held: @[FilterReset, "CapabilityBoundingSet=CAP_SYS_TIME"],
    removed: @["ProtectClock=no"], rootOnly: true),
  ProbeRow(name: "protect-hostname", setting: "ProtectHostname",
    probe: "hostname", held: @[FilterReset, "CapabilityBoundingSet=CAP_SYS_ADMIN"],
    removed: @["ProtectHostname=no"], rootOnly: true),
  ProbeRow(name: "restrict-namespaces-net", setting: "RestrictNamespaces",
    probe: "ns-net", held: @["CapabilityBoundingSet=CAP_SYS_ADMIN"],
    removed: @["RestrictNamespaces=no"], rootOnly: true),
  ProbeRow(name: "restrict-namespaces-uts", setting: "RestrictNamespaces",
    probe: "ns-uts", held: @["CapabilityBoundingSet=CAP_SYS_ADMIN"],
    removed: @["RestrictNamespaces=no"], rootOnly: true),
  ProbeRow(name: "restrict-namespaces-user", setting: "RestrictNamespaces",
    probe: "ns-user", removed: @["RestrictNamespaces=no"]),
  ProbeRow(name: "restrict-realtime", setting: "RestrictRealtime",
    probe: "realtime", held: @[FilterReset, "CapabilityBoundingSet=CAP_SYS_NICE"],
    removed: @["RestrictRealtime=no"], rootOnly: true),
  ProbeRow(name: "restrict-suid-sgid", setting: "RestrictSUIDSGID", probe: "suid",
    held: @["ReadWritePaths=/var/lib/a9probe"],
    removed: @["RestrictSUIDSGID=no"], rootOnly: true),
  ProbeRow(name: "lock-personality", setting: "LockPersonality",
    probe: "personality", held: @[FilterReset], removed: @["LockPersonality=no"]),
  ProbeRow(name: "memory-deny-write-execute", setting: "MemoryDenyWriteExecute",
    probe: "mdwe", removed: @["MemoryDenyWriteExecute=no"]),
  ProbeRow(name: "system-call-architectures", setting: "SystemCallArchitectures",
    probe: "arch", removed: @["SystemCallArchitectures="], amd64Only: true),
  ProbeRow(name: "system-call-error-number", setting: "SystemCallErrorNumber",
    probe: "filter", held: @["CapabilityBoundingSet=CAP_SYS_ADMIN"],
    removed: @["SystemCallErrorNumber="], expect: exErrnoNumber, rootOnly: true),
  ProbeRow(name: "system-call-filter", setting: "SystemCallFilter",
    probe: "filter", held: @["CapabilityBoundingSet=CAP_SYS_ADMIN"],
    removed: @[FilterReset], expect: exFilter, rootOnly: true),
  # The three network layers, each alone with the other two disabled
  # (C78: each is enough to stop a connect).
  ProbeRow(name: "private-network", setting: "PrivateNetwork", probe: "net",
    arg: "$IP", held: @["IPAddressDeny=", "RestrictAddressFamilies="],
    removed: @["PrivateNetwork=no"]),
  ProbeRow(name: "ip-address-deny", setting: "IPAddressDeny", probe: "net",
    arg: "$IP", held: @["PrivateNetwork=no", "RestrictAddressFamilies="],
    removed: @["IPAddressDeny="]),
  ProbeRow(name: "restrict-address-families", setting: "RestrictAddressFamilies",
    probe: "net", arg: "$IP", held: @["PrivateNetwork=no", "IPAddressDeny="],
    removed: @["RestrictAddressFamilies="], unlessValueHas: "AF_INET")]

const NotObservable* = [
  ("ProtectProc", "a root unit holding CAP_SYS_PTRACE sees every process " &
    "whatever hidepid= says (proc(5)), so =invisible has no effect a probe " &
    "inside the add-on's root units can observe"),
  ("ReadWritePaths", "not a restriction but the exception to ProtectSystem=strict; " &
    "its extent is what the protect-system row writes outside of")]

const DroppedKeys = ["ExecStart", "ExecStartPre", "ExecStartPost", "ExecStop",
  "ExecStopPost", "ExecReload", "ExecCondition", "Type", "Restart", "RestartSec",
  "RemainAfterExit", "TimeoutStartSec", "TimeoutStopSec", "WatchdogSec",
  "NotifyAccess", "StandardOutput", "StandardError", "StandardInput",
  "Environment", "EnvironmentFile", "LoadCredential", "LoadCredentialEncrypted",
  "SetCredential", "SetCredentialEncrypted", "ImportCredential", "OnFailure",
  "SuccessExitStatus", "KillMode", "TimeoutSec", "RuntimeMaxSec"]
  ## What a copy leaves out of the unit's ``[Service]``: its command and how
  ## systemd runs, stops and feeds it -- nothing that confines it.

proc serviceLines*(unit: string): seq[string] =
  ## The ``[Service]`` lines of ``unit``, comments and blanks dropped.
  var inService = false
  for raw in unit.splitLines():
    let l = raw.strip()
    if l.startsWith("["):
      inService = l == "[Service]"
      continue
    if inService and l.len > 0 and not l.startsWith("#") and not l.startsWith(";"):
      result.add(l)

proc keyOf(line: string): string =
  let i = line.find('=')
  if i < 0: "" else: line[0 ..< i].strip()

proc setsKey*(unit, key: string): bool =
  ## Whether the unit's ``[Service]`` assigns ``key`` a non-empty value
  ## (``no``/``false`` counts as not set).
  for l in serviceLines(unit):
    if keyOf(l) == key:
      let v = l[l.find('=') + 1 .. ^1].strip().toLowerAscii()
      result = v.len > 0 and v notin ["no", "false", "0", "off"]

proc runsAsRoot*(unit: string): bool =
  ## No ``User=`` and no ``DynamicUser=yes``.
  not setsKey(unit, "User") and not setsKey(unit, "DynamicUser")

proc probeUnitCopy*(unit, probeArgs, outFile: string;
                    extra: openArray[string]): string =
  ## A unit that runs the probe under ``unit``'s own confinement: every
  ## ``[Service]`` line of it but the ``DroppedKeys``, verbatim and in
  ## order, then ``extra`` (a row's HELD or REMOVED lines, which come last
  ## and so win or add, as systemd reads a drop-in). Its ``[Unit]`` names
  ## no dependency: the copy runs once, on its own.
  result = "[Unit]\nDescription=A9 confinement probe (test only)\n\n[Service]\n"
  for l in serviceLines(unit):
    if keyOf(l) notin DroppedKeys: result.add(l & "\n")
  result.add("Type=oneshot\nStandardOutput=file:" & outFile & "\n" &
             "StandardError=journal\nExecPaths=" & ProbePath.rsplit('/', 1)[0] &
             "\nExecStart=" & ProbePath & " " & probeArgs & "\n")
  for l in extra: result.add(l & "\n")

proc rowApplies*(row: ProbeRow; unit: string; amd64: bool): tuple[ok: bool; why: string] =
  ## Whether ``row`` runs in ``unit``, and why not.
  # An empty CapabilityBoundingSet= is the strictest value (no capability),
  # not an unset one.
  let present =
    if row.setting == "CapabilityBoundingSet":
      (block:
        var found = false
        for l in serviceLines(unit):
          if keyOf(l) == row.setting: found = true
        found)
    else: setsKey(unit, row.setting)
  if not present:
    return (false, "the unit does not set " & row.setting & "=")
  if row.rootOnly and not runsAsRoot(unit):
    return (false, "the probe needs root, and the unit runs unprivileged")
  if row.amd64Only and not amd64:
    return (false, "the probe is amd64 only")
  for k in row.impliedBy:
    if setsKey(unit, k):
      return (false, k & "= implies " & row.setting & "=, which a drop-in " &
        "cannot remove without removing " & k & "= itself")
  if row.unlessValueHas.len > 0:
    for l in serviceLines(unit):
      if keyOf(l) == row.setting and row.unlessValueHas in l:
        return (false, "the unit's " & row.setting & "= allows " &
          row.unlessValueHas & " by design (its own gate covers it)")
  if row.expect in {exErrnoNumber, exFilter} and not setsKey(unit, "SystemCallFilter"):
    return (false, "the unit sets no SystemCallFilter=")
  (true, "")

type Outcome* = tuple[ran: bool; rc, errno: int; killed: bool]

proc parseOutcome*(line, unitResult: string): Outcome =
  ## The probe's line ("A9PROBE <probe> <rc> <errno>") and the unit's
  ## ``Result=``: no line and a signal result is a kill.
  let w = line.strip().splitWhitespace()
  if w.len == 4 and w[0] == "A9PROBE":
    try: return (true, parseInt(w[2]), parseInt(w[3]), false)
    except ValueError: discard
  (false, 0, 0, unitResult.strip() == "signal")

proc heldOk*(e: Expect; o: Outcome): bool =
  case e
  of exBlocked: (o.ran and o.rc != 0) or o.killed
  of exErrnoNumber, exFilter: o.ran and o.rc != 0 and o.errno == 1

proc removedOk*(e: Expect; o: Outcome): bool =
  case e
  of exBlocked: o.ran and o.rc == 0
  of exErrnoNumber: o.killed
  of exFilter: o.ran and (o.rc == 0 or o.errno != 1)
