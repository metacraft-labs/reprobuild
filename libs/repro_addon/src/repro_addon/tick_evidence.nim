## The evidence a deploy-agent tick on an add-on host leaves (spec §10.4,
## threat model §9, DET-AO-8, DET-AO-10): a detection when its outcome is
## one threat model §9 names, and always a heartbeat carrying the outcome
## and the applied sequence.
##
## Every agent that ticks on an add-on host records through here: the
## add-on's own units (``agent_split``) and the full engine's
## ``repro deploy-agent`` (``engineAgentTick``, wired in
## ``repro_cli_support/deploy_agent``). An agent whose ticks left no record
## would make its host look silent to DET-AO-8 -- or, worse, look like a
## host that has nothing to report.
##
## Every tick also trips DET-AO-1's positive control (DET-4; spec §10.4
## "Scheduled positive controls"): ``manifestControl`` hands the agent's own
## selection a manifest signed by a key generated for the control, with the
## host's anchors, and the heartbeat says whether it was refused
## (``control``). The anchors are host state the heartbeat does not prove;
## the off-host check alerts when no tick proved them for a while.

import std/[strutils, times]

import repro_infra
import repro_infra/addon_diagnostics
import repro_peer_cache/auth as peerAuth
import repro_deploy_agent/agent
import repro_deploy_agent/manifest
import repro_deploy_agent/tick_record
import repro_deploy_agent/tick_status

import ./agent_checks
import ./contain_marker
import ./agent_record
import ./evidence
import ./evidence_ship
import ./generation0
import ./mutations

type
  TickRefusal* = object
    ## What the tick's apply refused of the input it was staged (DET-AO-2),
    ## and the bytes the record captures (EVID-1).
    refusal*: string
    payload*: string
    recorded*: bool          ## the refusal already left its own record
    manifestPayload*: string ## the staged envelope, for a manifest refusal
    stagingCopy*: string     ## where the refused staging is preserved
                             ## (named before the record is written, D6)
    compiler*: string        ## the profile compiler the apply unit's
    compilerSha256*: string  ## configuration names, and its SHA-256 as the
                             ## apply unit read it (not the compiler's own
                             ## claim, which is attacker-chosen)

proc tickIntervalMs*(confPath = EvidenceConfPath): int64 =
  ## The longest a tick may take to follow the previous one, from the
  ## evidence configuration (0 when unknown).
  try: int64(loadEvidenceConf(confPath).tickSec) * 1000
  except CatchableError: 0

proc tickDetection*(t: RecordedTick; r: TickRefusal):
    tuple[found: bool; detector: AddonDetector; trigger: string;
          offHostOnly: bool] =
  ## The detection a tick's outcome is, if any (threat model §9). A repeat
  ## (a quarantined deployment, a paused agent: reported on every tick) goes
  ## off-host only, so it does not fill the local record directory.
  if t.raised: return (true, edApplyRefusal, "tick-raised", false)
  let o = t.outcome
  case o.kind
  of aoRejected, aoAmbiguous:
    (true, edManifest, "addon-manifest-refused", false)
  of aoSecretsFailed: (true, edManifest, "sealed-section-failed", false)
  of aoApplyFailed:
    if r.refusal.len > 0:
      if r.recorded: (false, edApplyRefusal, "", false)
      else: (true, edApplyRefusal, "addon-staging-refused", false)
    elif $adStoreChanged in o.message: (true, edStore, "store-changed", false)
    else: (true, edApplyRefusal, "apply-failed", false)
  of aoStale:
    # The host half of DET-AO-10 (spec §9.2, threat model G32): the kind
    # the A8 record had, so its local file name is unchanged.
    (true, edFreshness, "stale-manifest", false)
  of aoRolledBack:
    if o.errorCode == "quarantined": (true, edRollback, "quarantined", true)
    else: (true, edRollback, "rolled-back", false)
  of aoPaused: (true, edRollback, "paused", true)
  of aoUnsupportedBase: (true, edApplyRefusal, "unsupported-base", false)
  of aoOperatorAction: (true, edApplyRefusal, "operator-action", false)
  else: (false, edApplyRefusal, "", false)

const
  ManifestControlSource* = "http://detector-control.invalid/manifest.rdm"
    ## The synthetic source the control's manifest is served from. Never
    ## fetched: ``manifestControl`` answers it in memory (``.invalid`` is
    ## reserved, RFC 2606, so it cannot name a real host either).

proc manifestControl*(target: string; anchors: TrustAnchors): string =
  ## DET-AO-1's positive control: the agent's selection (``selectManifest``,
  ## the code that refuses a manifest on a host) over one synthetic source
  ## serving a manifest for ``target`` signed by a key generated here, with
  ## the host's ``anchors``. It must end in ``aoRejected``, which the tick
  ## maps to DET-AO-1. Returns ``tripped``, ``not-run`` (no anchors: nothing
  ## to prove), or ``missed: <why>``. Fetches and writes nothing.
  if anchors.isNil: return "not-run"
  if target.len == 0: return "missed: the agent has no target"
  when mutated("manifest-control-skipped"):
    # FALSIFYING BUILD: the tick never runs the control.
    return "not-run"
  try:
    let key = peerAuth.generateKeypair()
    var m = DeployManifest(target: target, sequence: 1,
      deploymentId: "detector-control",
      profileText: "# DET-AO-1 positive control: never applied\n",
      issuedAt: uint64(getTime().toUnix()), maxAgeSeconds: 60)
    signManifest(key, m)
    let bytes = encodeManifest(m)
    var deps: AgentDeps
    deps.httpGet = proc(url: string; timeoutMs: int):
        tuple[ok: bool; missing: bool; body: seq[byte]; error: string] {.gcsafe.} =
      if url == ManifestControlSource: (true, false, bytes, "")
      else: (false, false, @[], "not the control's source: " & url)
    let sel = selectManifest(AgentConfig(target: target,
      sources: @[ManifestControlSource], anchors: anchors), deps)
    if sel.found:
      return "missed: a manifest signed by a key generated for the " &
        "control was ACCEPTED by the host's anchors"
    let d = tickDetection(RecordedTick(outcome: sel.outcome), TickRefusal())
    if sel.outcome.kind != aoRejected or not d.found or
        d.detector != edManifest:
      return "missed: the selection ended in " & $sel.outcome.kind &
        " (" & sel.outcome.errorCode & "), not a DET-AO-1 refusal"
    "tripped"
  except CatchableError as e:
    "missed: " & e.msg

proc recordTickEvidence*(t: RecordedTick; r: TickRefusal;
                         site = defaultSite(); anchors: TrustAnchors = nil) =
  ## The tick's records: its detection, if it is one, and its heartbeat
  ## (DET-AO-8), which carries the applied sequence the off-host lag check
  ## compares (DET-AO-10) and DET-AO-1's positive control over ``anchors``
  ## (``manifestControl``; ``not-run`` without them). A missed control is a
  ## DET-AO-1 detection of its own. Never raises: a record that cannot be
  ## written is reported on stderr (the journal), and the outcome stands.
  let o = t.outcome
  var fields = @[("outcome", if t.raised: "tickRaised" else: $o.kind),
                 ("target", o.target), ("sequence", $o.sequence),
                 ("deploymentId", o.deploymentId), ("errorCode", o.errorCode),
                 ("message", if t.raised: t.error else: o.message)]
  let d = tickDetection(t, r)
  if d.found and not mutated("tick-records-no-detection"):
    var payload = ""
    var extra: seq[(string, string)]
    # A refused compile keeps the A8 record's file name.
    let kind = if d.trigger == "addon-staging-refused" and
                   r.refusal.startsWith(CompiledProfileRefusal):
                 "compiled-profile-refused"
               else: d.trigger
    if d.trigger == "addon-manifest-refused":
      payload = r.manifestPayload
    elif d.trigger == "addon-staging-refused":
      payload = r.payload
      extra.add(("reason", r.refusal))
      when not mutated("refusal-names-no-copy"):
        if r.stagingCopy.len > 0: extra.add(("stagingCopy", r.stagingCopy))
        if r.compiler.len > 0:
          extra.add(("compiler", r.compiler))
          extra.add(("compilerSha256", r.compilerSha256))
    try:
      discard recordEvidence(EvidenceEvent(detector: d.detector,
        category: ecDetection, trigger: d.trigger, kind: kind,
        fields: fields & extra,
        payload: payload, attest: true, offHostOnly: d.offHostOnly), site)
    except CatchableError as e:
      stderr.write("repro-addon: cannot write the tick's evidence record: " &
        e.msg & "\n")
  let control = manifestControl(o.target, anchors)
  if control.startsWith("missed"):
    try:
      discard recordEvidence(EvidenceEvent(detector: edManifest,
        category: ecDetection, trigger: "manifest-control-missed",
        kind: "manifest-control-missed",
        fields: @[("target", o.target), ("message", "DET-AO-1's positive " &
          "control did not trip: " & control)], attest: true,
        # Repeated on every tick until it is fixed: off-host only, so it
        # does not fill the local record directory (the journal line below
        # is the host's copy).
        offHostOnly: true), site)
      stderr.write("repro-addon: DET-AO-1's positive control did not trip: " &
        control & "\n")
    except CatchableError as e:
      stderr.write("repro-addon: cannot write the control's record: " &
        e.msg & "\n")
  try:
    var applied = ""
    let cur = readCurrentGenerationId(site.stateDir)
    if cur.len > 0: applied = $readAgentRecord(site.stateDir, cur).sequence
    discard recordEvidence(EvidenceEvent(detector: edAgentTick,
      category: ecHeartbeat, trigger: "", kind: "tick",
      fields: fields & @[("intervalMs", $tickIntervalMs(site.confPath)),
                         ("appliedSequence", applied),
                         ("control", control),
                         ("count", $t.addOnDrift.len)],
      attest: true, offHostOnly: true), site)
  except CatchableError as e:
    stderr.write("repro-addon: cannot write the tick's heartbeat: " & e.msg &
      "\n")

proc engineAgentTick*(cfg: AgentConfig; deps: AgentDeps;
                      site: EvidenceSite): RecordedTick =
  ## One tick of the full engine's ``repro deploy-agent`` on an add-on host
  ## (decision 29: held to every A8 rule), recorded as the add-on agent's
  ## ticks are. ``site`` is the add-on's (``defaultSite(<add-on state>)``).
  # A contained host (decision 51): the engine's agent neither fetches nor
  # applies, and records nothing -- the containment record speaks for the
  # silence that follows (A11 review finding 6).
  if isContained(site.stateDir) and not mutated("contained-agent-applies"):
    result.outcome = AgentOutcome(kind: aoPaused, target: cfg.target,
      message: "contained by an operator (" &
        containedMarkerPath(site.stateDir) & "); nothing was fetched or applied")
    return
  result = runAgentTickRecorded(cfg, deps)
  when not mutated("engine-tick-unrecorded"):
    recordTickEvidence(result, TickRefusal(), site, cfg.anchors)
