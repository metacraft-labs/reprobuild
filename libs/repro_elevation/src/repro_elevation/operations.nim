## The closed, typed `PrivilegedOperation` set and the
## `requiresElevation` predicate (M81 deliverable 1 + 5).
##
## Per Elevation-And-Privileged-Operations.md "The Broker Executes A
## Closed, Typed Operation Set": the broker is NOT a "run anything as
## Administrator" service. It accepts only `PrivilegedOperation`
## records — each one a typed system-scope resource operation. There
## is no code path that runs a parent-supplied arbitrary command.
##
## M69's real system-scope resource catalog
## (`windows.optionalFeature`, `windows.capability`,
## `windows.service`, `windows.registryValue scope=system`,
## `fs.systemFile`, `systemd.systemUnit`, …) does not exist yet
## (M69 is `planned`). M81 ships the broker MECHANISM plus one real
## FIXTURE operation kind so the gate proves the mechanism
## end-to-end; the real catalog plugs into `dispatch.nim` at M69 by
## adding `PrivilegedOperationKind` entries and their drivers.
##
## This module is platform-pure and unit-testable everywhere.

import std/[strutils]

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
  case kind
  of pokFixtureFile: true
  of pokFixtureRegistry: true

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
  return ""
