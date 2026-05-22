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
## Phase A supports the four Windows system-scope resources:
##
##   windows.registryValue { key=... name=... kind=... value=... }
##   windows.optionalFeature { name=... }
##   windows.capability { name=... }
##   windows.service { name=... startType=... state=... }
##
## `fs.systemFile`, `env.systemVariable`, `windows.vsInstaller`, the
## POSIX surface, and `macos.systemDefault` are deferred — the parser
## rejects them with a clear "deferred to a later phase" diagnostic.

import std/[strutils, tables]

import repro_elevation

import ./errors

type
  SystemResourceKind* = enum
    srkWindowsRegistryValue = "windows.registryValue"
    srkWindowsOptionalFeature = "windows.optionalFeature"
    srkWindowsCapability = "windows.capability"
    srkWindowsService = "windows.service"

  SystemResource* = object
    ## One declared system-scope resource. `address` is the stable
    ## plan call-site identity; it defaults to a derivation of the
    ## real-world target when the stanza omits an explicit `address`.
    address*: string
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

  SystemProfile* = object
    ## The parsed `system.nim` — an ordered list of resources. The
    ## order is the apply order.
    resources*: seq[SystemResource]

const DeferredKinds = [
  "fs.systemFile", "env.systemVariable", "windows.vsInstaller",
  "macos.systemDefault", "systemd.systemUnit", "launchd.systemDaemon",
  "passwd.user"]

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
  ## parse. A quoted value may itself contain spaces.
  var assignments: seq[string]
  var current = ""
  for rawLine in body.splitLines():
    let line = stripComment(rawLine).strip()
    if line.len == 0:
      continue
    # A single physical line may carry several `key = value` pairs
    # (the compact single-line stanza form). Split on a heuristic:
    # an unquoted run of `whitespace <ident> =` starts a new pair.
    var i = 0
    var token = ""
    var inQuote = false
    while i < line.len:
      let c = line[i]
      if c == '"':
        inQuote = not inQuote
        token.add(c)
        inc i
      elif (not inQuote) and c in {' ', '\t'} and token.strip().len > 0:
        # Look ahead: `<ws>* <ident> <ws>* =` begins a new assignment.
        var j = i
        while j < line.len and line[j] in {' ', '\t'}: inc j
        var k = j
        while k < line.len and (line[k].isAlphaNumeric or line[k] == '_'):
          inc k
        var m = k
        while m < line.len and line[m] in {' ', '\t'}: inc m
        if k > j and m < line.len and line[m] == '=' and
           token.contains('='):
          assignments.add(token.strip())
          token = ""
          i = j
        else:
          token.add(c)
          inc i
      else:
        token.add(c)
        inc i
    if token.strip().len > 0:
      assignments.add(token.strip())
  return assignments

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
    if kindTag in DeferredKinds:
      raiseSystemProfileInvalid("resource kind '" & kindTag &
        "' is deferred to a later M69 phase (Phase A covers the four " &
        "Windows resources: windows.registryValue, " &
        "windows.optionalFeature, windows.capability, windows.service)")
    var srk: SystemResourceKind
    case kindTag
    of $srkWindowsRegistryValue: srk = srkWindowsRegistryValue
    of $srkWindowsOptionalFeature: srk = srkWindowsOptionalFeature
    of $srkWindowsCapability: srk = srkWindowsCapability
    of $srkWindowsService: srk = srkWindowsService
    else:
      raiseSystemProfileInvalid("unknown system resource kind '" &
        kindTag & "'")
    # Find the matching `}` (no nesting in this format).
    let closeIdx = clean.find('}', braceIdx + 1)
    if closeIdx < 0:
      raiseSystemProfileInvalid("resource '" & kindTag &
        "' block is not closed with '}'")
    let bodyText = clean[braceIdx + 1 ..< closeIdx]
    pos = closeIdx + 1
    # Collect `key = value` assignments.
    var fields = initTable[string, string]()
    for assignment in splitFieldAssignments(bodyText):
      let eq = assignment.find('=')
      if eq < 0:
        raiseSystemProfileInvalid("expected 'key = value' in resource '" &
          kindTag & "', got: '" & assignment & "'")
      let key = assignment[0 ..< eq].strip()
      let value = unquote(assignment[eq + 1 .. ^1])
      fields[key] = value
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
    res.address =
      if "address" in fields and fields["address"].len > 0: fields["address"]
      else: realWorldIdentity(res)
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

proc isDestructiveRollback*(r: SystemResource): bool =
  ## True when rolling this resource back would disable an Optional
  ## Feature or uninstall a Capability — the operations
  ## `--accept-feature-destroy` gates.
  r.kind in {srkWindowsOptionalFeature, srkWindowsCapability}
