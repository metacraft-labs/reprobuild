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

import std/[algorithm, os, sets, strutils, tables, times]

import blake3
import repro_elevation

import ./audit_log
import ./errors
import ./plan_envelope
import ./profile
import ./state_dir

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
     pokFsSystemFile, pokEnvSystemVariable, pokPasswdUser:
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
    of srkMacosSystemDefault: observeMacosSystemDefault(op)
    of srkSystemdSystemUnit: observeSystemdSystemUnit(op)
    of srkLaunchdSystemDaemon: observeLaunchdSystemDaemon(op)
    of srkFsSystemFile: observeFsSystemFile(op)
    of srkEnvSystemVariable: observeEnvSystemVariable(op)
    of srkPasswdUser: observePasswdUser(op)
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

type
  DependencyEdgeKind* = enum
    ## Why an edge was added — surfaced in diagnostics so a cycle error
    ## can tell the operator whether the offending edge came from a
    ## user-declared `depends_on` or from the producer / consumer map.
    edkExplicit = "explicit"             ## from a stanza's `depends_on`
    edkImplicit = "implicit"             ## from `ProducerConsumerMap`

  DependencyEdge* = object
    fromIdx*: int                        ## producer index (apply earlier)
    toIdx*: int                          ## consumer index (apply later)
    sourceKind*: DependencyEdgeKind

  DependencyGraph* = object
    ## A resolved dependency graph over a profile's resources. Nodes
    ## are identified by DECLARATION INDEX (the position in
    ## `profile.resources`), so the secondary stable order falls out of
    ## the indices without an extra address-comparison step.
    edges*: seq[DependencyEdge]

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
  ## user surface for typos / stale references); the cycle check
  ## itself runs in `topologicallyOrder`.
  # De-duplicate edges so a user who both declares a `depends_on` AND
  # benefits from the implicit producer-consumer entry sees one edge,
  # not two. The dedupe key is `(fromIdx, toIdx)`; the explicit
  # source-kind wins so a cycle diagnostic still names the user's
  # edge.
  var seen = initTable[(int, int), DependencyEdgeKind]()
  proc record(fromIdx, toIdx: int; src: DependencyEdgeKind) =
    if fromIdx == toIdx:
      # A self-edge would always cycle; refuse it at construction time
      # with a clear-attribution message — the cycle-detection path
      # below handles deeper loops.
      raisePlanCyclicDependency(@[
        profile.resources[fromIdx].address,
        profile.resources[fromIdx].address])
    let key = (fromIdx, toIdx)
    if key notin seen:
      seen[key] = src
    elif src == edkExplicit:
      # Promote an implicit entry to explicit when the user has also
      # declared it (so cycle diagnostics name the user's source).
      seen[key] = edkExplicit

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
      record(producerIdx, consumerIdx, edkExplicit)

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
        record(producerIdx, consumerIdx, edkImplicit)

  for key, src in seen.pairs:
    result.edges.add(DependencyEdge(fromIdx: key[0], toIdx: key[1],
                                    sourceKind: src))
  # Stable iteration order: sort edges by (fromIdx, toIdx) so the
  # graph is deterministic regardless of the table's hash iteration.
  result.edges.sort(proc(a, b: DependencyEdge): int =
    if a.fromIdx != b.fromIdx: cmp(a.fromIdx, b.fromIdx)
    else: cmp(a.toIdx, b.toIdx))

proc traceCycle(profile: SystemProfile;
                graph: DependencyGraph;
                inDegree: seq[int]): seq[string] =
  ## When Kahn's algorithm leaves nodes unprocessed, run a DFS over
  ## the surviving subgraph (nodes with `inDegree > 0` OR a node still
  ## reachable from one) to find a concrete cycle and return its
  ## resource-address sequence with the entry node repeated at the
  ## end. Used purely for the diagnostic; the cycle DETECTION is
  ## Kahn's "did we consume every node?" check.
  var adj: Table[int, seq[int]]
  for e in graph.edges:
    if e.fromIdx notin adj: adj[e.fromIdx] = @[]
    adj[e.fromIdx].add(e.toIdx)
  for k in adj.mvalues: k.sort()
  # Find a starting node still in-graph (in-degree > 0 OR has outgoing
  # edges to in-graph nodes). The smallest declaration index wins so
  # the diagnostic is stable across runs.
  var start = -1
  for i in 0 ..< profile.resources.len:
    if inDegree[i] > 0:
      start = i
      break
  if start < 0:
    return @[]                           # defensive — Kahn miscounted
  # Iterative DFS recording the path. The first node we revisit closes
  # the cycle; trim the prefix that doesn't participate.
  var stack: seq[int] = @[start]
  var path: seq[int] = @[start]
  var onStack: HashSet[int]
  onStack.incl(start)
  var iters: Table[int, int]
  iters[start] = 0
  while stack.len > 0:
    let node = stack[^1]
    let nexts = adj.getOrDefault(node, @[])
    var i = iters.getOrDefault(node, 0)
    var advanced = false
    while i < nexts.len:
      let nxt = nexts[i]
      inc i
      iters[node] = i
      if nxt in onStack:
        # Cycle closes at `nxt`. Trim path's prefix preceding the
        # first occurrence of `nxt`.
        var cycleStart = 0
        for k in 0 ..< path.len:
          if path[k] == nxt:
            cycleStart = k
            break
        var cyclePath: seq[string]
        for k in cycleStart ..< path.len:
          cyclePath.add(profile.resources[path[k]].address)
        cyclePath.add(profile.resources[nxt].address)
        return cyclePath
      if inDegree[nxt] > 0 and nxt notin onStack:
        stack.add(nxt)
        path.add(nxt)
        onStack.incl(nxt)
        iters[nxt] = 0
        advanced = true
        break
    if not advanced:
      discard stack.pop()
      discard path.pop()
      onStack.excl(node)
  return @[]

proc topologicallyOrder*(profile: SystemProfile;
                         graph: DependencyGraph): seq[int] =
  ## Return the resource declaration-indices in apply order: every
  ## producer before every consumer; ties broken by declaration index
  ## (stable secondary key). Kahn's algorithm with a min-priority
  ## "ready set" keyed by declaration index — independent ops keep
  ## their declaration order, which makes plan output byte-comparable
  ## across runs of the same profile text. Raises
  ## `EPlanCyclicDependency` (via `traceCycle`) when a cycle prevents
  ## ordering every node.
  let n = profile.resources.len
  var inDegree = newSeq[int](n)
  var outAdj = newSeq[seq[int]](n)
  for e in graph.edges:
    outAdj[e.fromIdx].add(e.toIdx)
    inc inDegree[e.toIdx]
  # Ready set: every node whose in-degree is currently 0. To honor
  # stable declaration order we pop the smallest index first — using a
  # sorted-on-insert array (n is small in practice, profiles rarely
  # exceed a few hundred resources).
  var ready: seq[int]
  for i in 0 ..< n:
    if inDegree[i] == 0:
      ready.add(i)
  while ready.len > 0:
    # The minimum index is at position 0 because `ready` is kept
    # sorted; we always insert into the right place below.
    let node = ready[0]
    ready.delete(0)
    result.add(node)
    for nxt in outAdj[node]:
      dec inDegree[nxt]
      if inDegree[nxt] == 0:
        # Insertion-sort to keep `ready` ordered by declaration index.
        var pos = ready.len
        for j in 0 ..< ready.len:
          if ready[j] > nxt:
            pos = j
            break
        ready.insert(nxt, pos)
  if result.len < n:
    # Cycle: trace one and raise.
    raisePlanCyclicDependency(traceCycle(profile, graph, inDegree))

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
