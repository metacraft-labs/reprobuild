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
