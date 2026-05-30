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

import ./errors

type
  SystemResourceKind* = enum
    srkWindowsRegistryValue = "windows.registryValue"
    srkWindowsOptionalFeature = "windows.optionalFeature"
    srkWindowsCapability = "windows.capability"
    srkWindowsService = "windows.service"
    srkWindowsVsInstaller = "windows.vsInstaller"
    srkWindowsFirewallRule = "windows.firewallRule"
    srkMacosSystemDefault = "macos.systemDefault"
    srkSystemdSystemUnit = "systemd.systemUnit"
    srkLaunchdSystemDaemon = "launchd.systemDaemon"
    srkFsSystemFile = "fs.systemFile"
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
    of srkLaunchdSystemDaemon:
      sdaLabel*: string
      sdaProgramArgs*: seq[string]
      sdaRunAtLoad*: bool
    of srkFsSystemFile:
      sfPath*: string
      sfContent*: string
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

  SystemProfile* = object
    ## The parsed `system.nim` — an ordered list of resources. The
    ## order is the apply order.
    resources*: seq[SystemResource]

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
  of srkWindowsVsInstaller:
    "vsInstaller:" & r.vsEdition &
      (if r.vsInstallPath.len > 0: "@" & r.vsInstallPath else: "")
  of srkWindowsFirewallRule:
    "firewallRule:" & r.fwName
  of srkMacosSystemDefault:
    "systemDefault:" & r.sdDomain & ":" & r.sdKey
  of srkSystemdSystemUnit:
    "systemUnit:" & r.suName
  of srkLaunchdSystemDaemon:
    "systemDaemon:" & r.sdaLabel
  of srkFsSystemFile:
    "systemFile:" & r.sfPath
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
  of srkWindowsVsInstaller: r.vsEdition
  of srkWindowsFirewallRule: r.fwName
  of srkMacosSystemDefault: r.sdDomain & ":" & r.sdKey
  of srkSystemdSystemUnit: r.suName
  of srkLaunchdSystemDaemon: r.sdaLabel
  of srkFsSystemFile: r.sfPath
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

# ---------------------------------------------------------------------------
# The declarative-format parser. Pure — no filesystem access.
# ---------------------------------------------------------------------------

proc stripComment(line: string): string =
  ## Drop a `#`-comment, but not a `#` inside a quoted value.
  var inQuote = false
  for i in 0 ..< line.len:
    let c = line[i]
    if c == '"':
      inQuote = not inQuote
    elif c == '#' and not inQuote:
      return line[0 ..< i]
  return line

proc unquote(v: string): string =
  let t = v.strip()
  if t.len >= 2 and t[0] == '"' and t[^1] == '"':
    return t[1 ..< t.len - 1]
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

proc parseSystemProfile*(text: string): SystemProfile =
  ## Parse the declarative `system.nim` text into a `SystemProfile`.
  ## Raises `ESystemProfileInvalid` on any structural error or an
  ## unknown / deferred resource kind. Brace-aware: a stanza body may
  ## be on one line (`kind { k = v }`) or spread across many.
  # Strip comments globally, then walk by `{` / `}` braces.
  var clean = ""
  for line in text.splitLines():
    clean.add(stripComment(line))
    clean.add('\n')
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
    let kindTag = clean[pos ..< braceIdx].strip()
    var srk: SystemResourceKind
    case kindTag
    of $srkWindowsRegistryValue: srk = srkWindowsRegistryValue
    of $srkWindowsOptionalFeature: srk = srkWindowsOptionalFeature
    of $srkWindowsCapability: srk = srkWindowsCapability
    of $srkWindowsService: srk = srkWindowsService
    of $srkWindowsVsInstaller: srk = srkWindowsVsInstaller
    of $srkWindowsFirewallRule: srk = srkWindowsFirewallRule
    of $srkMacosSystemDefault: srk = srkMacosSystemDefault
    of $srkSystemdSystemUnit: srk = srkSystemdSystemUnit
    of $srkLaunchdSystemDaemon: srk = srkLaunchdSystemDaemon
    of $srkFsSystemFile: srk = srkFsSystemFile
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
    else:
      raiseSystemProfileInvalid("unknown system resource kind '" &
        kindTag & "'")
    # Find the matching `}` (no nesting in this format). A `}` inside
    # a double-quoted string is skipped — required for kinds whose
    # content field carries JS / shell bodies (e.g.
    # `linux.polkitRule content = "polkit.addRule(function() { ... });"`).
    var closeIdx = -1
    block:
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
      raiseSystemProfileInvalid("resource '" & kindTag &
        "' block is not closed with '}'")
    let bodyText = clean[braceIdx + 1 ..< closeIdx]
    pos = closeIdx + 1
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
      res = SystemResource(kind: srkWindowsService,
        serviceName: need("name"),
        serviceStartType: st,
        serviceRunning: stateStr == "running")
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
    of srkMacosSystemDefault:
      res = SystemResource(kind: srkMacosSystemDefault,
        sdDomain: need("domain"),
        sdKey: need("key"),
        sdValueType: (if "type" in fields: fields["type"] else: "-string"),
        sdValueLiteral: (if "value" in fields: fields["value"] else: ""),
        sdRestartTarget: (if "restartTarget" in fields:
          fields["restartTarget"] else: ""))
    of srkSystemdSystemUnit:
      res = SystemResource(kind: srkSystemdSystemUnit,
        suName: need("name"),
        suContent: need("content"),
        suEnabled:
          if "enabled" in fields: parseBoolField("enabled",
            fields["enabled"]) else: true)
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
      res = SystemResource(kind: srkFsSystemFile,
        sfPath: need("path"),
        sfContent: (if "content" in fields: fields["content"] else: ""))
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
      serviceRunning: r.serviceRunning)
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
      suContent: r.suContent,
      suEnabled: r.suEnabled,
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
      sfDestroy: destroy)
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
