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

import std/[os, strutils, tables, times]

import blake3
import repro_core
import repro_core/dep_graph as repro_core_dep_graph
import repro_elevation

import ./audit_log
import ./errors
import ./plan_envelope
import ./profile
import ./state_dir

# Re-export the shared graph kernel's value types + enum members so
# callers of `repro_infra` see the same names they did before the
# M82 DRY refactor. `Graph` / `GraphEdge` / `EdgeKind` / `edkExplicit`
# / `edkImplicit` / `addEdge` / `traceCycle` / `EGraphCycle` all
# become reachable through `import repro_infra` without forcing
# every consumer to also `import repro_core`.
export repro_core_dep_graph

type
  ResourceObservation* = object
    ## What the planner observed for one resource — used both for the
    ## plan's baseline digest and, at apply time, for stale-detection.
    address*: string
    present*: bool
    observedDigestHex*: string

  DriftClassification* = enum
    ## M82 Phase C: classification of plan-time external drift.
    ##
    ## The planner compares THREE digests for each resource:
    ##
    ##   * `recorded`  — the `postWriteDigest` from the previously-
    ##                   applied generation's audit log (RBSL record).
    ##                   Absent for a first-ever apply.
    ##   * `observed`  — the live state the planner just observed.
    ##   * `desired`   — the digest derived from the current profile.
    ##
    ## With `recorded` present and `recorded != observed`, two cases
    ## emerge:
    dcInformational = "informational"
      ## The world changed since the last apply, BUT it now matches
      ## desired. Surface as a heads-up; the apply will no-op the
      ## resource. (E.g. an operator manually applied the same change
      ## the profile asks for.)
    dcActionable = "actionable"
      ## The world changed since the last apply AND it does not match
      ## desired either. A third party modified state out of band.
      ## The apply will overwrite the third-party change with the
      ## profile's desired state. The operator should review.

  DriftFinding* = object
    ## One per-resource plan-time external-drift finding (M82 Phase C).
    ## A `DriftFinding` is REPORTING ONLY: its presence does NOT cause
    ## the planner to refuse a plan. Operator-facing flags
    ## (`--accept-drift` / `--reconcile-drift`) translate findings into
    ## a plan-time baseline rewrite; a future `--strict-no-drift` flag
    ## (not yet wired) would refuse plan emission.
    address*: string
    kind*: string                          ## resource kindTag
    recordedDigestHex*: string             ## previously-applied postWriteDigest
    observedDigestHex*: string             ## live digest the planner just saw
    desiredDigestHex*: string              ## desired digest from the profile
    classification*: DriftClassification
    accepted*: bool
      ## True when `--accept-drift` / `--reconcile-drift` was supplied
      ## at plan time and the planner rewrote the plan's baseline to
      ## the observed state. The finding is still emitted (so the audit
      ## log + plan output record what was accepted), but the plan
      ## itself proceeds as if the new state were the recorded baseline.

  PlannerOptions* = object
    ## M82 Phase C: knobs that influence `producePlan`'s drift handling.
    ## All fields default to the conservative behavior — drift is
    ## SURFACED in `result.driftFindings` but never blocks plan
    ## emission, and the plan's baselines reflect what the planner
    ## observed (which is what apply-time live-state refresh needs
    ## per M82 Phase A).
    stateDir*: string
      ## When non-empty, the planner reads the previously-applied
      ## generation's RBSL audit log and uses its per-resource
      ## `postWriteDigest` as the `recorded` digest for drift
      ## comparison. An empty `stateDir`, or a state dir with no
      ## active generation, means "first apply ever" — no drift
      ## comparison is performed.
    acceptDrift*: bool
      ## The plan-time `--accept-drift` / `--reconcile-drift` flag.
      ## When set, every actionable `DriftFinding` is marked
      ## `accepted = true` for the audit record; functionally the
      ## planner's baseline ALWAYS reflects the observed state under
      ## M82 Phase A's live-state-refresh model, so the flag's
      ## behavior is symmetric with the no-flag case — the difference
      ## is the annotation, which lets `repro infra apply` and the
      ## RBSL audit log record whether the operator acknowledged the
      ## drift or simply did not see it.

  PlanResult* = object
    ## The full output of `repro infra plan`.
    envelope*: PlanEnvelope
    observations*: seq[ResourceObservation]
    driftFindings*: seq[DriftFinding]
      ## M82 Phase C: per-resource plan-time external-drift findings.
      ## Emitted even when no flag is set; consumed by the CLI for
      ## human-readable output and (transitively) the RBSL audit log.

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

proc desiredDigestForKind*(op: PrivilegedOperation): string =
  ## The desired-state digest for any M69 system-scope operation. The
  ## four Phase-A kinds use `windows_system_driver.systemDesired
  ## DigestHex`; the Phase-B `windows.vsInstaller` kind uses
  ## `windows_vs_installer_driver.vsInstallerDesiredDigestHex`; the
  ## six Phase-C POSIX/macOS kinds use
  ## `posix_system_driver.posixSystemDesiredDigestHex`.
  case op.kind
  of pokWindowsVsInstaller:
    vsInstallerDesiredDigestHex(op)
  of pokMacosSystemDefault, pokSystemdSystemUnit, pokLaunchdSystemDaemon,
     pokFsSystemFile, pokEnvSystemVariable, pokPasswdUser,
     pokLinuxSysctl, pokLinuxUdevRule, pokLinuxPolkitRule,
     pokLinuxTmpfilesRule, pokLinuxSudoersRule, pokPasswdGroup,
     pokLinuxNixDaemonSetting:
    posixSystemDesiredDigestHex(op)
  else:
    systemDesiredDigestHex(op)

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
    of srkWindowsVsInstaller: observeWindowsVsInstaller(op)
    of srkWindowsFirewallRule: observeWindowsFirewallRule(op)
    of srkMacosSystemDefault: observeMacosSystemDefault(op)
    of srkSystemdSystemUnit: observeSystemdSystemUnit(op)
    of srkLaunchdSystemDaemon: observeLaunchdSystemDaemon(op)
    of srkFsSystemFile: observeFsSystemFile(op)
    of srkEnvSystemVariable: observeEnvSystemVariable(op)
    of srkPasswdUser: observePasswdUser(op)
    of srkOsTimezone:
      when defined(windows):
        observeWindowsOsTimezone(op)
      else:
        observePosixOsTimezone(op)
    of srkOsHostname:
      when defined(windows):
        observeWindowsOsHostname(op)
      else:
        observePosixOsHostname(op)
    of srkLinuxSysctl:
      observeLinuxSysctl(op)
    of srkLinuxUdevRule:
      observeLinuxUdevRule(op)
    of srkLinuxPolkitRule:
      observeLinuxPolkitRule(op)
    of srkLinuxTmpfilesRule:
      observeLinuxTmpfilesRule(op)
    of srkLinuxSudoersRule:
      observeLinuxSudoersRule(op)
    of srkPasswdGroup:
      observePasswdGroup(op)
    of srkLinuxNixDaemonSetting:
      observeLinuxNixDaemonSetting(op)
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
  of srkWindowsVsInstaller:
    action & " vs-installer " & r.vsEdition & " (" &
      $r.vsWorkloads.len & " workload(s), " & $r.vsComponents.len &
      " component(s)" & (if r.vsStrict: ", strict" else: "") & ")"
  of srkWindowsFirewallRule:
    action & " firewall-rule " & r.fwName & " (" &
      r.fwProtocol & "/" & r.fwDirection & "/" & r.fwAction &
      (if r.fwLocalPort.len > 0: ", port " & r.fwLocalPort else: "") &
      (if r.fwEnabled: ", enabled" else: ", disabled") & ")"
  of srkMacosSystemDefault:
    action & " system-default " & r.sdDomain & " " & r.sdKey
  of srkSystemdSystemUnit:
    action & " system-unit " & r.suName &
      (if r.suEnabled: " (enable)" else: " (no-enable)")
  of srkLaunchdSystemDaemon:
    action & " system-daemon " & r.sdaLabel
  of srkFsSystemFile:
    action & " system-file " & r.sfPath
  of srkEnvSystemVariable:
    action & " system-variable " & r.evName & " (+" &
      $r.evContribution.len & " entr" &
      (if r.evContribution.len == 1: "y" else: "ies") & ")"
  of srkPasswdUser:
    action & " user " & r.puName &
      (if r.puGroups.len > 0: " groups=" & $r.puGroups.len else: "")
  of srkOsTimezone:
    action & " timezone " & r.tzIana
  of srkOsHostname:
    action & " hostname " & r.hostnameName
  of srkLinuxSysctl:
    action & " sysctl " & r.sysctlKey & " = " & r.sysctlValue
  of srkLinuxUdevRule:
    action & " udev-rule " & r.udevName
  of srkLinuxPolkitRule:
    action & " polkit-rule " & r.polkitName
  of srkLinuxTmpfilesRule:
    action & " tmpfiles-rule " & r.tmpfilesName &
      (if r.tmpfilesApplyNow: " (apply-now)" else: " (boot-only)")
  of srkLinuxSudoersRule:
    action & " sudoers-rule " & r.sudoersName
  of srkPasswdGroup:
    action & " group " & r.pgName &
      (if r.pgGid.len > 0: " (gid=" & r.pgGid & ")" else: "") &
      (if r.pgMembers.len > 0: " members=" & $r.pgMembers.len else: "")
  of srkLinuxNixDaemonSetting:
    action & " nix-daemon-setting " & r.nixKey & " = " & r.nixValue

# ---------------------------------------------------------------------------
# Resource dependency graph + topological sort (M82 Phase B).
#
# The planner orders the emitted plan so a CONSUMER op always applies
# AFTER its PRODUCER. Two edge sources feed the graph:
#
#   1. EXPLICIT — the user's `depends_on = ["kind:name", ...]` on a
#      stanza. Each entry resolves to a producer resource present in
#      the same profile; the producer -> consumer edge is added.
#      Unresolved entries fail closed at plan time so a typo never
#      becomes a silently-ignored dependency.
#
#   2. IMPLICIT — the shared `producer_consumer_map.ProducerConsumerMap`.
#      For every resource the planner sees, `lookupProducedResources`
#      asks "what resources does this producer register / configure as
#      a side effect of being installed?"; for every match present in
#      the SAME profile, a producer -> consumer edge is added.
#      Critical case: a profile with `windows.capability OpenSSH.Server`
#      + `windows.service sshd` orders the capability before the
#      service WITHOUT the user writing `depends_on` (the M69 sshd
#      scenario that motivated M82).
#
# The graph is a DAG; a cycle (explicit, or explicit + implicit) is
# refused with `EPlanCyclicDependency` naming the cycle path. The sort
# uses Kahn's algorithm with a STABLE secondary key (declaration index)
# so two ops with no dependency between them keep their declaration
# order — the emitted plan is byte-comparable across runs of the same
# profile text.
# ---------------------------------------------------------------------------

# The generic graph algorithms — Kahn's topological sort, cycle-trace,
# explicit-vs-implicit edge dedupe — live in `repro_core/dep_graph.nim`
# as a single shared kernel that knows nothing about `SystemProfile`,
# resource addresses, or the producer / consumer map. This module is
# the SYSTEM-SCOPE ADAPTER over that kernel: it owns the
# `SystemProfile`-to-graph translation, the `depends_on`-to-edge
# resolution, the implicit producer / consumer edge inference, and the
# cycle-index-to-address translation when a cycle is detected. The home
# scope has a parallel adapter in
# `libs/repro_home_apply/src/repro_home_apply/dep_graph.nim`.

type
  DependencyEdgeKind* = EdgeKind
    ## Re-export of the shared module's edge-kind enum. Preserved
    ## under the system-scope name so existing call sites that name
    ## the type explicitly still compile. New code should reach for
    ## `EdgeKind` directly.

  DependencyEdge* = GraphEdge
    ## Re-export of the shared module's edge type. The fields are
    ## `fromIdx`, `toIdx`, and `kind` (was `sourceKind` in the
    ## pre-refactor system-scope copy).

  DependencyGraph* = Graph
    ## Re-export of the shared module's graph type. Adds `nodeCount`
    ## alongside `edges`; the old system-scope copy implied
    ## `nodeCount` from `profile.resources.len` at the call site.

proc findResourceIndex(profile: SystemProfile;
                       depKind, depName: string): int =
  ## Return the declaration index of the resource matching
  ## `(depKind, depName)`, or `-1` if none. Matching is by
  ## `resourceKindTag` + `resourceName` — the same pair the
  ## `depends_on` syntax names. The match is EXACT (no prefix
  ## semantics for explicit edges — the user wrote a literal name and
  ## the planner respects it; the prefix logic is reserved for the
  ## implicit `ProducerConsumerMap` matching, which is the layer that
  ## knows about version-tagged capability suffixes).
  for i in 0 ..< profile.resources.len:
    let r = profile.resources[i]
    if resourceKindTag(r) == depKind and resourceName(r) == depName:
      return i
  return -1

proc buildDependencyGraph*(profile: SystemProfile): DependencyGraph =
  ## Resolve every explicit `depends_on` entry + every implicit
  ## producer / consumer fact into an edge set over the profile's
  ## resources. Pure — no observation, no I/O. Raises
  ## `ESystemProfileInvalid` if an explicit `depends_on` entry refers
  ## to a `(kind, name)` no resource in the profile satisfies (the
  ## user surface for typos / stale references); raises
  ## `EPlanCyclicDependency` on a SELF-edge with the resource's
  ## address named directly. Multi-node cycles are detected later in
  ## `topologicallyOrder`.
  result = DependencyGraph(nodeCount: profile.resources.len)

  proc record(g: var DependencyGraph; fromIdx, toIdx: int;
              src: EdgeKind) =
    if fromIdx == toIdx:
      # A self-edge would always cycle; refuse it at construction time
      # with a clear-attribution message that names the offending
      # address directly. The shared kernel's generic
      # `EGraphCycle` is the wrong tool here — we have a strictly
      # better diagnostic available at the adapter layer.
      raisePlanCyclicDependency(@[
        profile.resources[fromIdx].address,
        profile.resources[fromIdx].address])
    addEdge(g, fromIdx, toIdx, src)

  # 1. EXPLICIT edges from each stanza's `depends_on`.
  for consumerIdx in 0 ..< profile.resources.len:
    let r = profile.resources[consumerIdx]
    for dep in r.dependsOn:
      let producerIdx = findResourceIndex(profile, dep.kind, dep.name)
      if producerIdx < 0:
        raiseSystemProfileInvalid("resource '" & r.address &
          "' depends_on '" & dep.kind & ":" & dep.name &
          "' but no resource in the profile satisfies that " &
          "(kind, name) pair")
      record(result, producerIdx, consumerIdx, edkExplicit)

  # 2. IMPLICIT edges from the shared producer / consumer map. For
  # every resource we treat it as a candidate producer; if any
  # consumer it would register is present in the profile, link
  # producer -> consumer. Prefix matching is the map's responsibility
  # (a version-tagged capability matches its bare prefix entry).
  for producerIdx in 0 ..< profile.resources.len:
    let r = profile.resources[producerIdx]
    let consumers = lookupProducedResources(resourceKindTag(r),
                                            resourceName(r))
    for c in consumers:
      let consumerIdx = findResourceIndex(profile, c.kind, c.name)
      if consumerIdx >= 0:
        record(result, producerIdx, consumerIdx, edkImplicit)

proc topologicallyOrder*(profile: SystemProfile;
                         graph: DependencyGraph): seq[int] =
  ## Return the resource declaration-indices in apply order: every
  ## producer before every consumer; ties broken by declaration index
  ## (stable secondary key). Delegates to the shared kernel's
  ## `topologicallyOrder`; on a multi-node cycle the kernel's
  ## `EGraphCycle.cyclePath` (a seq of node indices) is translated
  ## here into a `seq[string]` of system-scope resource addresses and
  ## rewrapped as `EPlanCyclicDependency` — the operator-facing
  ## exception type the M82 Phase B contract names.
  try:
    repro_core.topologicallyOrder(graph)
  except EGraphCycle as e:
    var addressPath: seq[string]
    for idx in e.cyclePath:
      addressPath.add(profile.resources[idx].address)
    raisePlanCyclicDependency(addressPath)

# ---------------------------------------------------------------------------
# M82 Phase C — plan-time external drift detection.
#
# Per Planner-Apply-Refresh-Model.md "Layer 2 — External drift at plan
# time": the planner reads the previously-applied generation's recorded
# state and compares it against current observation. The recorded state
# lives in the RBSL audit log of the active generation; the
# `postWriteDigest` of the most recent record per resource address is
# the "what we LAST left it at" digest. (M62/M63/M68 home-scope and
# M69 system-scope manifests already record this; M82 Phase C READS
# it without changing the on-disk format.)
#
# The classification is a three-way digest comparison:
#
#   * recorded == observed                    -> no drift
#   * recorded != observed AND observed == desired
#                                             -> informational drift
#                                                (world changed, but
#                                                 the change agrees
#                                                 with the profile)
#   * recorded != observed AND observed != desired
#                                             -> actionable drift
#                                                (third-party out-of-band
#                                                 modification; the apply
#                                                 will overwrite it)
#   * recorded absent (first apply ever)      -> no drift
#
# The drift findings are REPORTED in the `PlanResult` — they do not
# block plan emission. A future `--strict-no-drift` flag (not yet
# wired; the hook is `PlannerOptions.acceptDrift`) would refuse plan
# emission when an actionable finding is present.
# ---------------------------------------------------------------------------

proc loadRecordedDigests*(stateDir: string): Table[string, string] =
  ## Return the per-resource `postWriteDigest` of the most-recent
  ## record (the "what we LAST left it at" snapshot) for the active
  ## generation in `stateDir`. An empty result is returned for:
  ##
  ##   * an empty `stateDir`;
  ##   * a state dir with no `current` pointer (first apply ever);
  ##   * a state dir whose active generation has no apply.log yet.
  ##
  ## A corrupt or unreadable log degrades silently to "no recorded
  ## state" — drift detection is advisory and the alternative would be
  ## an unrecoverable plan-time failure on an audit-log issue
  ## orthogonal to the planner's purpose.
  if stateDir.len == 0:
    return
  let genId = readCurrentGenerationId(stateDir)
  if genId.len == 0:
    return
  let logPath = applyLogPath(stateDir, genId)
  if not fileExists(logPath):
    return
  var records: AuditReadResult
  try:
    records = readAuditLog(logPath)
  except EAuditLogCorrupt:
    return                                # advisory; degrade silently
  except CatchableError:
    return
  for rec in records.records:
    if rec.resourceAddress.len == 0:
      continue
    # `appendAuditRecord` is append-only; later records for the same
    # address (e.g. a re-apply that turned a no-op into an applied)
    # overwrite earlier ones — that matches the desired "what we LAST
    # left it at" semantics.
    result[rec.resourceAddress] = rec.postDigestHex

proc classifyDrift*(recorded, observed, desired: string): DriftClassification =
  ## Pure three-way digest comparison. The caller has already filtered
  ## out the "no recorded state" case (a first apply ever); both
  ## non-drift outcomes (`recorded == observed`, and the "no recorded
  ## state" case the caller handles) yield no `DriftFinding` and are
  ## therefore not represented in the enum. This proc is only invoked
  ## when `recorded != observed`, where exactly two classifications
  ## remain.
  if observed == desired:
    dcInformational
  else:
    dcActionable

# ---------------------------------------------------------------------------
# The planner.
# ---------------------------------------------------------------------------

proc producePlan*(profileText: string; hostIdentity: string;
                  now: int64 = -1;
                  opts = PlannerOptions()): PlanResult =
  ## Build a plan from a `system.nim` profile text. Parses the
  ## profile, observes every resource's live state, decides per-
  ## resource actions, builds the M82 Phase B dependency graph
  ## (explicit `depends_on` + implicit producer / consumer edges),
  ## topologically orders the operations, and assembles the `RBIP`
  ## envelope. Read-only and non-elevated. The emitted ops appear in
  ## TOPOLOGICAL order with declaration index as the stable secondary
  ## key — so a producer's op is always before its consumer's,
  ## independent ops keep their declaration order, and the plan output
  ## is byte-comparable across runs of the same profile text. A cycle
  ## in the graph raises `EPlanCyclicDependency` with the cycle's
  ## resource-address path.
  ##
  ## M82 Phase C: when `opts.stateDir` points at a previously-applied
  ## generation, the planner additionally compares each resource's
  ## recorded `postWriteDigest` (from the active generation's RBSL
  ## audit log) against current observation and surfaces external
  ## drift in `result.driftFindings`. The findings are REPORTING
  ## ONLY — they do not block plan emission. `opts.acceptDrift`
  ## annotates the findings with `accepted = true` so the audit
  ## record shows the operator acknowledged the drift; the plan's
  ## baselines reflect the observed state in either case (M82
  ## Phase A's live-state-refresh model means the recorded baseline
  ## is advisory, not load-bearing, at apply time).
  let profile = parseSystemProfile(profileText)
  let graph = buildDependencyGraph(profile)
  let order = topologicallyOrder(profile, graph)
  let createdTs = if now >= 0: now else: getTime().toUnix()
  let profileDigest = digestProfileText(profileText)
  let recordedDigests = loadRecordedDigests(opts.stateDir)
  var env: PlanEnvelope
  env.schemaVersion = PlanSchemaVersion
  env.createdTimestamp = createdTs
  env.hostIdentity = hostIdentity
  env.profileDigestHex = profileDigest
  for idx in order:
    let r = profile.resources[idx]
    let obs = observeResource(r)
    result.observations.add(obs)
    let op = toPrivilegedOperation(r)
    let desired = desiredDigestForKind(op)
    let action = decideAction(obs, desired, destroy = false)
    env.operations.add(PlannedOperationRecord(
      address: r.address,
      kindTag: $op.kind,
      privileged: requiresElevation(op.kind),
      action: action,
      baselineDigestHex: obs.observedDigestHex,
      desiredDigestHex: desired,
      summary: summaryLine(r, action)))
    # Drift detection — M82 Phase C. Skip on no-recorded-state (first
    # apply, missing audit entry). Skip when recorded == observed
    # (the world matches what we LAST left it at).
    if r.address in recordedDigests:
      let recorded = recordedDigests[r.address]
      if recorded.len > 0 and recorded != obs.observedDigestHex:
        result.driftFindings.add(DriftFinding(
          address: r.address,
          kind: $op.kind,
          recordedDigestHex: recorded,
          observedDigestHex: obs.observedDigestHex,
          desiredDigestHex: desired,
          classification: classifyDrift(recorded, obs.observedDigestHex,
                                        desired),
          accepted: opts.acceptDrift))
  env.planId = computePlanId(profileDigest, hostIdentity, createdTs)
  result.envelope = env

# ---------------------------------------------------------------------------
# Human-readable drift output (CLI surface).
# ---------------------------------------------------------------------------

proc renderDriftFindings*(findings: seq[DriftFinding]): string =
  ## Format a non-empty `driftFindings` seq into the lines
  ## `repro infra plan` / `repro system sync` print verbatim. Empty
  ## input yields an empty string so the caller can guard on length.
  if findings.len == 0:
    return ""
  var lines: seq[string]
  var actionable = 0
  var informational = 0
  for f in findings:
    if f.classification == dcActionable: inc actionable
    else: inc informational
  lines.add("External drift detected since the previously-applied " &
    "generation:")
  for f in findings:
    let label =
      case f.classification
      of dcActionable: "actionable"
      of dcInformational: "informational"
    let acc = if f.accepted: " (accepted via --accept-drift)" else: ""
    lines.add("  - " & f.address & "  [" & label & "]" & acc)
    lines.add("      kind     : " & f.kind)
    lines.add("      recorded : " & f.recordedDigestHex)
    lines.add("      observed : " & f.observedDigestHex)
    lines.add("      desired  : " & f.desiredDigestHex)
  if actionable > 0:
    lines.add("  " & $actionable & " actionable drift finding(s) — " &
      "review before re-running `repro infra apply`.")
    lines.add("  Pass --accept-drift to acknowledge the drift; the " &
      "apply will overwrite it with the profile's desired state.")
  if informational > 0:
    lines.add("  " & $informational & " informational drift finding(s) — " &
      "the world changed but already matches desired; the apply " &
      "will no-op these.")
  lines.join("\n")

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
