## M83 Phase D — `ProfileIntent -> SystemProfile` (system-scope) adapter.
##
## The Phase A `repro_profile` macro library builds a `ProfileIntent`
## value at compile-time. The system-apply pipeline (M69-M82) was
## written before the compile-then-apply pipeline existed and consumes
## a parsed `SystemProfile` (the M69 declarative-text IR from
## `libs/repro_infra/src/repro_infra/profile.nim`).
##
## This adapter builds a `SystemProfile` value that is BYTE-EQUIVALENT
## — under the apply pipeline's reads — to what `parseSystemProfile`
## would have produced from the equivalent legacy text. Only
## system-scope resource kinds appear in the resulting profile;
## activities, config, and hosts are no-ops (the system parser has no
## syntax for those blocks — `system.nim` profiles are bare resource
## stanzas).
##
## Resource-kind mapping (macro side -> apply parser side):
##
##   windows.registryValueHKLM  ->  windows.registryValue
##
## All other kinds use the same string form on both sides because the
## Phase A constructor names are themselves derived from the M69
## `SystemResourceKind` string-enum values.

import std/[strutils, tables]

import repro_elevation
import repro_profile
import repro_infra

proc fieldString(r: ResourceIntent; key: string;
                 default: string = ""): string =
  if key notin r.fields:
    return default
  let fv = r.fields[key]
  case fv.kind
  of fvkString: fv.s
  of fvkInt: $fv.i
  of fvkBool: (if fv.b: "true" else: "false")
  of fvkExpr: fv.expr
  of fvkList:
    var s = ""
    for i, item in fv.items:
      if i > 0:
        s.add(',')
      s.add(item)
    s

proc fieldBool(r: ResourceIntent; key: string;
               default: bool = false): bool =
  if key notin r.fields:
    return default
  let fv = r.fields[key]
  case fv.kind
  of fvkBool: fv.b
  of fvkString:
    case fv.s.toLowerAscii()
    of "true", "yes", "on", "1": true
    of "false", "no", "off", "0": false
    else: default
  of fvkInt: fv.i != 0
  of fvkExpr: default
  of fvkList: default

proc fieldList(r: ResourceIntent; key: string): seq[string] =
  if key notin r.fields:
    return @[]
  let fv = r.fields[key]
  case fv.kind
  of fvkList: fv.items
  of fvkString:
    if fv.s.len == 0:
      return @[]
    var items: seq[string]
    for piece in fv.s.split(','):
      let t = piece.strip()
      if t.len > 0:
        items.add(t)
    items
  else: @[]

proc buildSystemResource(r: ResourceIntent): SystemResource =
  ## Map a `ResourceIntent` to a `SystemResource`. The caller is
  ## responsible for filtering out non-system-scope kinds before
  ## invoking this proc.
  case r.kind
  of "windows.registryValueHKLM", "windows.registryValue":
    let key = fieldString(r, "key")
    let valueKindTag = fieldString(r, "kind", "string")
    if not isKnownSystemRegistryValueKind(valueKindTag):
      raise newException(ValueError,
        "windows.registryValueHKLM 'kind' '" & valueKindTag &
        "' is not a known typed value kind")
    result = SystemResource(kind: srkWindowsRegistryValue,
      regKey: key,
      regName: fieldString(r, "name"),
      regValueKind: systemRegistryValueKindFromString(valueKindTag),
      regValueLiteral: fieldString(r, "value"))
  of "windows.optionalFeature":
    result = SystemResource(kind: srkWindowsOptionalFeature,
      featureName: fieldString(r, "name"),
      featureEnabled: fieldBool(r, "enabled", true))
  of "windows.capability":
    result = SystemResource(kind: srkWindowsCapability,
      capabilityName: fieldString(r, "name"),
      capabilityInstalled: fieldBool(r, "installed", true))
  of "windows.service":
    let st = fieldString(r, "startType", "Automatic")
    let stateStr = fieldString(r, "state", "running").toLowerAscii()
    result = SystemResource(kind: srkWindowsService,
      serviceName: fieldString(r, "name"),
      serviceStartType: st,
      serviceRunning: stateStr == "running")
  of "windows.vsInstaller":
    result = SystemResource(kind: srkWindowsVsInstaller,
      vsEdition: fieldString(r, "edition", fieldString(r, "version")),
      vsChannel: fieldString(r, "channel", "Release"),
      vsInstallPath: fieldString(r, "installPath"),
      vsWorkloads: fieldList(r, "workloads"),
      vsComponents: fieldList(r, "components"),
      vsStrict: fieldBool(r, "strict", false))
  of "windows.firewallRule":
    let protocol = fieldString(r, "protocol")
    if protocol notin FirewallProtocols:
      raise newException(ValueError,
        "windows.firewallRule protocol '" & protocol &
        "' is not one of " & FirewallProtocols.join(" / "))
    let direction = fieldString(r, "direction")
    if direction notin FirewallDirections:
      raise newException(ValueError,
        "windows.firewallRule direction '" & direction &
        "' is not one of " & FirewallDirections.join(" / "))
    let action = fieldString(r, "action")
    if action notin FirewallActions:
      raise newException(ValueError,
        "windows.firewallRule action '" & action &
        "' is not one of " & FirewallActions.join(" / "))
    result = SystemResource(kind: srkWindowsFirewallRule,
      fwName: fieldString(r, "name"),
      fwDisplayName: fieldString(r, "displayName"),
      fwProtocol: protocol,
      fwDirection: direction,
      fwAction: action,
      fwLocalPort: fieldString(r, "localPort"),
      fwEnabled: fieldBool(r, "enabled", true))
  of "macos.systemDefault":
    result = SystemResource(kind: srkMacosSystemDefault,
      sdDomain: fieldString(r, "domain"),
      sdKey: fieldString(r, "key"),
      sdValueType: fieldString(r, "type", "-string"),
      sdValueLiteral: fieldString(r, "value"),
      sdRestartTarget: fieldString(r, "restartTarget"))
  of "systemd.systemUnit":
    result = SystemResource(kind: srkSystemdSystemUnit,
      suName: fieldString(r, "name"),
      suContent: fieldString(r, "content"),
      suEnabled: fieldBool(r, "enabled", true))
  of "launchd.systemDaemon":
    result = SystemResource(kind: srkLaunchdSystemDaemon,
      sdaLabel: fieldString(r, "label"),
      sdaProgramArgs: fieldList(r, "programArgs"),
      sdaRunAtLoad: fieldBool(r, "runAtLoad", true))
  of "fs.systemFile":
    result = SystemResource(kind: srkFsSystemFile,
      sfPath: fieldString(r, "path"),
      sfContent: fieldString(r, "content"))
  of "env.systemVariable":
    result = SystemResource(kind: srkEnvSystemVariable,
      evName: fieldString(r, "name"),
      evContribution: fieldList(r, "contribute"),
      evIsPathList: fieldBool(r, "isPathList", false))
  of "passwd.user":
    result = SystemResource(kind: srkPasswdUser,
      puName: fieldString(r, "name"),
      puHome: fieldString(r, "home"),
      puShell: fieldString(r, "shell"),
      puGroups: fieldList(r, "extraGroups"))
  of "os.timezone":
    let iana = fieldString(r, "tz")
    if not isSafeIanaTimezone(iana):
      raise newException(ValueError,
        "os.timezone tz '" & iana &
        "' contains characters outside the IANA charset")
    if not isMappedIanaTimezone(iana):
      raise newException(ValueError,
        "os.timezone tz '" & iana &
        "' is not in the embedded IANA -> Windows mapping table")
    result = SystemResource(kind: srkOsTimezone, tzIana: iana)
  of "os.hostname":
    let h = fieldString(r, "hostname")
    if not isSafeHostname(h):
      raise newException(ValueError,
        "os.hostname '" & h & "' is not a valid RFC 1123 hostname")
    result = SystemResource(kind: srkOsHostname, hostnameName: h)
  of "linux.sysctl":
    let k = fieldString(r, "key")
    let v = fieldString(r, "value")
    if not isSafeSysctlKey(k):
      raise newException(ValueError,
        "linux.sysctl key '" & k &
        "' contains characters outside the sysctl-key charset")
    if not isSafeSysctlValue(v):
      raise newException(ValueError,
        "linux.sysctl value for key '" & k &
        "' contains a newline")
    let filename = fieldString(r, "filename")
    if filename.len > 0:
      if not isSafeDropInBasename(filename):
        raise newException(ValueError,
          "linux.sysctl filename '" & filename &
          "' is not a safe single-segment basename")
      if not filename.endsWith(".conf"):
        raise newException(ValueError,
          "linux.sysctl filename '" & filename &
          "' must end with '.conf'")
    result = SystemResource(kind: srkLinuxSysctl,
      sysctlKey: k, sysctlValue: v, sysctlFilename: filename)
  of "linux.udevRule":
    let n = fieldString(r, "name")
    let c = fieldString(r, "content")
    if not isSafeDropInBasename(n):
      raise newException(ValueError,
        "linux.udevRule name '" & n &
        "' is not a safe single-segment basename")
    if not n.endsWith(".rules"):
      raise newException(ValueError,
        "linux.udevRule name '" & n & "' must end with '.rules'")
    result = SystemResource(kind: srkLinuxUdevRule,
      udevName: n, udevContent: c)
  of "linux.polkitRule":
    let n = fieldString(r, "name")
    let c = fieldString(r, "content")
    if not isSafeDropInBasename(n):
      raise newException(ValueError,
        "linux.polkitRule name '" & n &
        "' is not a safe single-segment basename")
    if not n.endsWith(".rules"):
      raise newException(ValueError,
        "linux.polkitRule name '" & n & "' must end with '.rules'")
    result = SystemResource(kind: srkLinuxPolkitRule,
      polkitName: n, polkitContent: c)
  of "linux.tmpfilesRule":
    let n = fieldString(r, "name")
    let c = fieldString(r, "content")
    if not isSafeDropInBasename(n):
      raise newException(ValueError,
        "linux.tmpfilesRule name '" & n &
        "' is not a safe single-segment basename")
    if not n.endsWith(".conf"):
      raise newException(ValueError,
        "linux.tmpfilesRule name '" & n & "' must end with '.conf'")
    result = SystemResource(kind: srkLinuxTmpfilesRule,
      tmpfilesName: n, tmpfilesContent: c,
      tmpfilesApplyNow: fieldBool(r, "applyNow", true))
  of "linux.sudoersRule":
    let n = fieldString(r, "name")
    let c = fieldString(r, "content")
    if not isSafeDropInBasename(n):
      raise newException(ValueError,
        "linux.sudoersRule name '" & n &
        "' is not a safe single-segment basename")
    if n.contains('.'):
      raise newException(ValueError,
        "linux.sudoersRule name '" & n &
        "' must not contain '.' (sudo silently ignores dotted files)")
    result = SystemResource(kind: srkLinuxSudoersRule,
      sudoersName: n, sudoersContent: c)
  of "passwd.group":
    let n = fieldString(r, "name")
    if not isSafePosixUserOrGroupName(n):
      raise newException(ValueError,
        "passwd.group name '" & n &
        "' is not a valid POSIX group name")
    let gidStr = fieldString(r, "gid")
    if not isSafeGid(gidStr):
      raise newException(ValueError,
        "passwd.group gid '" & gidStr &
        "' is not a non-negative decimal integer")
    let members = fieldList(r, "members")
    for m in members:
      if not isSafePosixUserOrGroupName(m):
        raise newException(ValueError,
          "passwd.group member '" & m &
          "' is not a valid POSIX user name")
    result = SystemResource(kind: srkPasswdGroup,
      pgName: n, pgGid: gidStr, pgMembers: members)
  else:
    raise newException(ValueError,
      "unknown system-scope resource kind: '" & r.kind & "'")
  result.address =
    if r.address.len > 0: r.address
    else: realWorldIdentity(result)
  var deps: seq[ResourceDependency] = @[]
  for d in r.dependsOn:
    deps.add((kind: d.kind, name: d.name))
  result.dependsOn = deps

proc isSystemScopeResource(kind: string): bool =
  ## System-scope resource kinds (M69 + M82). The home-scope kinds
  ## (env.userPath, env.userVariable, fs.managedBlock, shell.integration,
  ## windows.registryValueHKCU, windows.startup, fs.userFile) are
  ## filtered out and handled by the home adapter instead.
  case kind
  of "windows.registryValueHKLM",
     "windows.optionalFeature", "windows.capability",
     "windows.service", "windows.vsInstaller",
     "windows.firewallRule",
     "macos.systemDefault", "systemd.systemUnit",
     "launchd.systemDaemon", "fs.systemFile",
     "env.systemVariable", "passwd.user",
     "os.timezone", "os.hostname",
     "linux.sysctl", "linux.udevRule", "linux.polkitRule",
     "linux.tmpfilesRule", "linux.sudoersRule",
     "passwd.group":
    true
  else:
    false

proc profileIntentToSystemProfile*(p: ProfileIntent): SystemProfile =
  ## Build a `SystemProfile` value equivalent to what
  ## `parseSystemProfile(text)` would return for the same logical
  ## profile. Activities, config, and hosts are no-ops at system scope
  ## (the M69 parser has no syntax for them — `system.nim` is bare
  ## resource stanzas).
  ##
  ## Mapping:
  ##   ProfileIntent.resources filtered to system-scope kinds ->
  ##     seq[SystemResource] with SystemResourceKind tags + per-kind fields.
  for r in p.resources:
    if not isSystemScopeResource(r.kind):
      continue
    result.resources.add(buildSystemResource(r))

# ---------------------------------------------------------------------------
# `SystemProfile -> text` round-tripper.
#
# Phase D wires the compile-then-adapt path into `repro infra apply`. The
# infra library's public entry points (`runInfraApply`, `producePlan`,
# `detectStaleResources`, `plannedOperationsFor`, every rollback hook)
# all take `profileText: string` and reparse it internally via
# `parseSystemProfile`. To minimise the touch surface of Phase D, the
# CLI re-emits a CANONICAL text representation of the adapted profile
# and feeds THAT down — `parseSystemProfile` of the rendered text is
# equal to the adapted `SystemProfile` by construction.
#
# This is NOT a general-purpose serializer; the rendering is just
# correct enough to round-trip every `SystemResource` field the M69
# parser reads. Comments, ordering of unrelated fields, and exact
# whitespace are not preserved (they have no semantic meaning).
# ---------------------------------------------------------------------------

proc quoteSystemValue(s: string): string =
  ## Quote a string for the system-profile text format. The parser
  ## reads `"..."` literals; backslashes and embedded quotes are
  ## NOT escaped by the M69 parser (`unquote` strips one surrounding
  ## pair and stops), so we reject embedded quotes outright — the
  ## adapter is fed by `ProfileIntent` values whose strings would be
  ## authored at Nim source level, where embedded quotes already need
  ## explicit escaping, so this is a structural invariant rather than
  ## an arbitrary restriction.
  if '"' in s:
    raise newException(ValueError,
      "system-profile string value contains an embedded double quote; " &
      "the M69 text format cannot represent this verbatim")
  "\"" & s & "\""

proc renderListLiteral(items: openArray[string]): string =
  result = "["
  for i, item in items:
    if i > 0:
      result.add(", ")
    result.add(quoteSystemValue(item))
  result.add(']')

proc renderDependsOnLiteral(deps: openArray[ResourceDependency]): string =
  result = "["
  for i, d in deps:
    if i > 0:
      result.add(", ")
    result.add(quoteSystemValue(d.kind & ":" & d.name))
  result.add(']')

proc appendStanza(buf: var string; kindTag: string;
                  pairs: seq[(string, string)];
                  deps: openArray[ResourceDependency]) =
  buf.add(kindTag)
  buf.add(" {\n")
  for (k, v) in pairs:
    buf.add("  ")
    buf.add(k)
    buf.add(" = ")
    buf.add(v)
    buf.add('\n')
  if deps.len > 0:
    buf.add("  depends_on = ")
    buf.add(renderDependsOnLiteral(deps))
    buf.add('\n')
  buf.add("}\n\n")

proc renderSystemProfileToText*(sp: SystemProfile): string =
  ## Serialize a `SystemProfile` into the canonical declarative text
  ## that `parseSystemProfile` consumes. The result is the SAME profile
  ## by structural equality: `parseSystemProfile(renderSystemProfileToText(sp))`
  ## produces a `SystemProfile` byte-equal to `sp`. Used by the Phase D
  ## `repro infra apply` integration to feed the existing
  ## `runInfraApply(text, opts)` lib entry point with the
  ## compile-then-adapt output without restructuring the infra lib API.
  for r in sp.resources:
    var pairs: seq[(string, string)] = @[]
    case r.kind
    of srkWindowsRegistryValue:
      pairs.add(("key", quoteSystemValue(r.regKey)))
      pairs.add(("name", quoteSystemValue(r.regName)))
      pairs.add(("kind", quoteSystemValue($r.regValueKind)))
      pairs.add(("value", quoteSystemValue(r.regValueLiteral)))
    of srkWindowsOptionalFeature:
      pairs.add(("name", quoteSystemValue(r.featureName)))
      pairs.add(("enabled", (if r.featureEnabled: "true" else: "false")))
    of srkWindowsCapability:
      pairs.add(("name", quoteSystemValue(r.capabilityName)))
      pairs.add(("installed",
        (if r.capabilityInstalled: "true" else: "false")))
    of srkWindowsService:
      pairs.add(("name", quoteSystemValue(r.serviceName)))
      pairs.add(("startType", quoteSystemValue(r.serviceStartType)))
      pairs.add(("state",
        quoteSystemValue(if r.serviceRunning: "running" else: "stopped")))
    of srkWindowsVsInstaller:
      pairs.add(("edition", quoteSystemValue(r.vsEdition)))
      pairs.add(("channel", quoteSystemValue(r.vsChannel)))
      if r.vsInstallPath.len > 0:
        pairs.add(("installPath", quoteSystemValue(r.vsInstallPath)))
      pairs.add(("workloads", renderListLiteral(r.vsWorkloads)))
      pairs.add(("components", renderListLiteral(r.vsComponents)))
      pairs.add(("strict", (if r.vsStrict: "true" else: "false")))
    of srkWindowsFirewallRule:
      pairs.add(("name", quoteSystemValue(r.fwName)))
      if r.fwDisplayName.len > 0:
        pairs.add(("displayName", quoteSystemValue(r.fwDisplayName)))
      pairs.add(("protocol", quoteSystemValue(r.fwProtocol)))
      pairs.add(("direction", quoteSystemValue(r.fwDirection)))
      pairs.add(("action", quoteSystemValue(r.fwAction)))
      if r.fwLocalPort.len > 0:
        pairs.add(("localPort", quoteSystemValue(r.fwLocalPort)))
      pairs.add(("enabled", (if r.fwEnabled: "true" else: "false")))
    of srkMacosSystemDefault:
      pairs.add(("domain", quoteSystemValue(r.sdDomain)))
      pairs.add(("key", quoteSystemValue(r.sdKey)))
      pairs.add(("type", quoteSystemValue(r.sdValueType)))
      pairs.add(("value", quoteSystemValue(r.sdValueLiteral)))
      if r.sdRestartTarget.len > 0:
        pairs.add(("restartTarget", quoteSystemValue(r.sdRestartTarget)))
    of srkSystemdSystemUnit:
      pairs.add(("name", quoteSystemValue(r.suName)))
      pairs.add(("content", quoteSystemValue(r.suContent)))
      pairs.add(("enabled", (if r.suEnabled: "true" else: "false")))
    of srkLaunchdSystemDaemon:
      pairs.add(("label", quoteSystemValue(r.sdaLabel)))
      pairs.add(("programArgs", renderListLiteral(r.sdaProgramArgs)))
      pairs.add(("runAtLoad",
        (if r.sdaRunAtLoad: "true" else: "false")))
    of srkFsSystemFile:
      pairs.add(("path", quoteSystemValue(r.sfPath)))
      pairs.add(("content", quoteSystemValue(r.sfContent)))
    of srkEnvSystemVariable:
      pairs.add(("name", quoteSystemValue(r.evName)))
      pairs.add(("contribute", renderListLiteral(r.evContribution)))
      pairs.add(("isPathList",
        (if r.evIsPathList: "true" else: "false")))
    of srkPasswdUser:
      pairs.add(("name", quoteSystemValue(r.puName)))
      if r.puHome.len > 0:
        pairs.add(("home", quoteSystemValue(r.puHome)))
      if r.puShell.len > 0:
        pairs.add(("shell", quoteSystemValue(r.puShell)))
      pairs.add(("groups", renderListLiteral(r.puGroups)))
    of srkOsTimezone:
      pairs.add(("tz", quoteSystemValue(r.tzIana)))
    of srkOsHostname:
      pairs.add(("hostname", quoteSystemValue(r.hostnameName)))
    of srkLinuxSysctl:
      pairs.add(("key", quoteSystemValue(r.sysctlKey)))
      pairs.add(("value", quoteSystemValue(r.sysctlValue)))
      if r.sysctlFilename.len > 0:
        pairs.add(("filename", quoteSystemValue(r.sysctlFilename)))
    of srkLinuxUdevRule:
      pairs.add(("name", quoteSystemValue(r.udevName)))
      pairs.add(("content", quoteSystemValue(r.udevContent)))
    of srkLinuxPolkitRule:
      pairs.add(("name", quoteSystemValue(r.polkitName)))
      pairs.add(("content", quoteSystemValue(r.polkitContent)))
    of srkLinuxTmpfilesRule:
      pairs.add(("name", quoteSystemValue(r.tmpfilesName)))
      pairs.add(("content", quoteSystemValue(r.tmpfilesContent)))
      pairs.add(("applyNow",
        (if r.tmpfilesApplyNow: "true" else: "false")))
    of srkLinuxSudoersRule:
      pairs.add(("name", quoteSystemValue(r.sudoersName)))
      pairs.add(("content", quoteSystemValue(r.sudoersContent)))
    of srkPasswdGroup:
      pairs.add(("name", quoteSystemValue(r.pgName)))
      if r.pgGid.len > 0:
        pairs.add(("gid", quoteSystemValue(r.pgGid)))
      pairs.add(("members", renderListLiteral(r.pgMembers)))
    pairs.add(("address", quoteSystemValue(r.address)))
    appendStanza(result, $r.kind, pairs, r.dependsOn)
