## `repro infra plan` — the non-mutating, non-elevated planner (M69).
##
## Per System-Profile-And-Infra-Apply.md "repro infra plan": the plan
## runs FULLY non-elevated and read-only. It observes every resource's
## live state (registry reads, `Get-WindowsOptionalFeature`,
## `Get-WindowsCapability`, `Get-Service` are all read-only and need
## no Administrator token), decides the per-resource action, and
## partitions the operations into non-privileged vs privileged via
## M81's `partition.nim`.
##
## The result is an `RBIP` plan envelope; `repro infra apply` refers
## to it by id and re-checks staleness against the live world.
##
## For M69 Phase A every resource in a `system.nim` profile is a
## Windows system-scope resource and therefore privileged — the
## `nonPrivilegedOperationCount` the partition records is 0 for a
## pure-Windows profile. The partition machinery is still exercised
## so the same code path serves a future mixed home+system apply.

import std/[os, times]

import blake3
import repro_elevation

import ./errors
import ./plan_envelope
import ./profile

type
  ResourceObservation* = object
    ## What the planner observed for one resource — used both for the
    ## plan's baseline digest and, at apply time, for stale-detection.
    address*: string
    present*: bool
    observedDigestHex*: string

  PlanResult* = object
    ## The full output of `repro infra plan`.
    envelope*: PlanEnvelope
    observations*: seq[ResourceObservation]

proc digestProfileText*(profileText: string): string =
  ## BLAKE3 hex of the raw profile text — pins the plan to the exact
  ## `system.nim` it was produced from.
  var buf = newSeq[byte](profileText.len)
  for i, ch in profileText:
    buf[i] = byte(ord(ch))
  let d = blake3.digest(buf)
  result = newStringOfCap(64)
  const hex = "0123456789abcdef"
  for b in d:
    result.add(hex[int(b shr 4)])
    result.add(hex[int(b and 0x0f)])

# ---------------------------------------------------------------------------
# Live observation of one declared resource. Pure-read — no mutation,
# no elevation. Delegates to the M69 `windows_system_driver` observe
# entry points (the SAME drivers the broker uses).
# ---------------------------------------------------------------------------

proc observeResource*(r: SystemResource): ResourceObservation =
  ## Re-observe a declared resource's live state. Read-only.
  result.address = r.address
  let op = toPrivilegedOperation(r)
  let obs =
    case r.kind
    of srkWindowsRegistryValue: observeWindowsRegistryValue(op)
    of srkWindowsOptionalFeature: observeWindowsOptionalFeature(op)
    of srkWindowsCapability: observeWindowsCapability(op)
    of srkWindowsService: observeWindowsService(op)
  result.present = obs.present
  result.observedDigestHex =
    if obs.present: obs.digestHex else: ZeroDigestHex

# ---------------------------------------------------------------------------
# Per-resource action decision — the M68 `decideAction` contract:
#
#   observed absent                          -> create
#   observed digest == desired digest         -> no-op (cache-hit)
#   observed digest != desired                -> update
#
# The planner does NOT itself fail-closed on drift — that is the
# broker's re-observe gate at apply time. The plan simply records the
# baseline digest it saw; if the world moves before apply, the apply
# detects the staleness (`EPlanStale`) or the broker detects the
# drift (`EBrokerDrift`).
# ---------------------------------------------------------------------------

proc decideAction*(obs: ResourceObservation; desiredDigestHex: string;
                   destroy: bool): string =
  if destroy:
    if not obs.present: "no-op" else: "destroy"
  elif not obs.present:
    "create"
  elif obs.observedDigestHex == desiredDigestHex:
    "no-op"
  else:
    "update"

proc summaryLine(r: SystemResource; action: string): string =
  case r.kind
  of srkWindowsRegistryValue:
    action & " " & r.regKey & "\\" & r.regName & " (" &
      $r.regValueKind & ")"
  of srkWindowsOptionalFeature:
    action & " optional-feature " & r.featureName &
      (if r.featureEnabled: " (enable)" else: " (disable)")
  of srkWindowsCapability:
    action & " capability " & r.capabilityName &
      (if r.capabilityInstalled: " (install)" else: " (uninstall)")
  of srkWindowsService:
    action & " service " & r.serviceName & " startType=" &
      r.serviceStartType & " state=" &
      (if r.serviceRunning: "Running" else: "Stopped")

# ---------------------------------------------------------------------------
# The planner.
# ---------------------------------------------------------------------------

proc producePlan*(profileText: string; hostIdentity: string;
                  now: int64 = -1): PlanResult =
  ## Build a plan from a `system.nim` profile text. Parses the
  ## profile, observes every resource's live state, decides per-
  ## resource actions, and assembles the `RBIP` envelope. Read-only
  ## and non-elevated.
  let profile = parseSystemProfile(profileText)
  let createdTs = if now >= 0: now else: getTime().toUnix()
  let profileDigest = digestProfileText(profileText)
  var env: PlanEnvelope
  env.schemaVersion = PlanSchemaVersion
  env.createdTimestamp = createdTs
  env.hostIdentity = hostIdentity
  env.profileDigestHex = profileDigest
  for r in profile.resources:
    let obs = observeResource(r)
    result.observations.add(obs)
    let op = toPrivilegedOperation(r)
    let desired = systemDesiredDigestHex(op)
    let action = decideAction(obs, desired, destroy = false)
    env.operations.add(PlannedOperationRecord(
      address: r.address,
      kindTag: $op.kind,
      privileged: requiresElevation(op.kind),
      action: action,
      baselineDigestHex: obs.observedDigestHex,
      desiredDigestHex: desired,
      summary: summaryLine(r, action)))
  env.planId = computePlanId(profileDigest, hostIdentity, createdTs)
  result.envelope = env

# ---------------------------------------------------------------------------
# Plan -> partition. The privileged operations the broker (or the
# already-elevated fast path) will run.
# ---------------------------------------------------------------------------

proc planPartition*(profileText: string;
                    env: PlanEnvelope): ApplyPartition =
  ## Re-derive the typed `PrivilegedOperation` set for a plan and run
  ## the M81 partition. Only the EFFECTIVE (non-no-op) privileged
  ## operations are handed to the broker; a no-op needs no mutation.
  let profile = parseSystemProfile(profileText)
  var byAddress = newSeq[(string, SystemResource)]()
  for r in profile.resources:
    byAddress.add((r.address, r))
  var privilegedCandidates: seq[PrivilegedOperation]
  for op in env.operations:
    if op.action == "no-op":
      continue
    for (resAddr, r) in byAddress:
      if resAddr == op.address:
        privilegedCandidates.add(toPrivilegedOperation(r))
        break
  partitionApply(privilegedCandidates, nonPrivilegedOperationCount = 0)

# ---------------------------------------------------------------------------
# Stale detection — `repro infra apply <plan-id>`.
# ---------------------------------------------------------------------------

proc detectStaleResources*(planObservations: seq[PlannedOperationRecord];
                           profileText: string): seq[string] =
  ## Re-observe every resource and compare the live digest against
  ## the digest the plan recorded. A resource whose live state no
  ## longer matches either the plan baseline OR the plan's desired
  ## value is STALE — the apply must refuse with `EPlanStale`.
  ##
  ## A resource that has converged to its desired value since the
  ## plan was produced is NOT stale (the plan would simply no-op it);
  ## only a divergence the plan did not foresee is stale.
  let profile = parseSystemProfile(profileText)
  var resByAddress = newSeq[(string, SystemResource)]()
  for r in profile.resources:
    resByAddress.add((r.address, r))
  for rec in planObservations:
    var found: SystemResource
    var has = false
    for (resAddr, r) in resByAddress:
      if resAddr == rec.address:
        found = r
        has = true
        break
    if not has:
      result.add(rec.address)           # plan references a vanished resource
      continue
    let obs = observeResource(found)
    if obs.observedDigestHex == rec.baselineDigestHex or
       obs.observedDigestHex == rec.desiredDigestHex:
      continue                          # consistent with the plan
    result.add(rec.address)
