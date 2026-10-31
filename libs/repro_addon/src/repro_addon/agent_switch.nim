## The deploy agent on an add-on host (ReproOS Add-On Mode §9, §7.4, §7.5,
## §9.3): every agent apply goes through the add-on switch, so it takes the
## host lock, writes the pending marker, is ledgered, is retained as an
## add-on generation that records its ``deploymentId`` and sequence, and can
## be rolled back with `repro system rollback`. Both agent entry points use
## this module: the full engine's `repro deploy-agent` (which compiles a Nim
## profile first and keeps its legacy `--secrets-dir`) and the static
## binary's `repro system addon agent-tick` (canonical text, add-on secrets).
##
## Migration. A host whose agent applied before this existed (rpi2: plain
## `repro infra apply` generations in the agent's own state directory, and
## only generation 0 in the add-on's) is taken over by one switch of the
## profile the agent last applied, read from its current generation. Every
## object that profile declares is on the host already, byte for byte, so
## the switch adopts each one without writing it and restarts nothing (spec
## §9 "Migration"). The next apply then diffs the new manifest against that
## generation like any other.

import std/[json, os, strutils]

import repro_deploy_agent
import repro_deploy_agent/apply_hook
import repro_infra
import repro_infra/addon_diagnostics
import repro_profile

import ./addon_apply
import ./agent_record
import ./static_tree

type
  AddonApplyFn* = proc(o: AddonApplyOptions): AddonApplyResult {.closure,
                                                               gcsafe.}
    ## `runAddonApply` in production; a test records the options.

proc hostAddonStateDir*(pointer = AddonStateDirPointer): string =
  ## The add-on's state directory on this host: the one bootstrap recorded,
  ## else the default.
  let recorded = readAddonStateDirPointer(pointer)
  if recorded.len > 0: recorded else: DefaultStateDir

proc agentRecordOf*(m: DeployManifest): AgentRecord =
  AgentRecord(deploymentId: m.deploymentId, sequence: m.sequence)

proc defaultAddonApply(): AddonApplyFn =
  result = proc(o: AddonApplyOptions): AddonApplyResult {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      runAddonApply(o)

proc addonAgentApplyHook*(stateDir, hostIdentity: string;
                          agentStateDir = "";
                          resolver: ProfileResolver = nil;
                          dispatcher: BuildActionDispatcher = nil;
                          apply: AddonApplyFn = nil;
                          driftSink: proc(d: string) {.closure, gcsafe.} = nil):
    ApplyHook =
  ## The agent's apply on an add-on host: the manifest's profile (compiled
  ## first when ``resolver`` is given, the full engine's case) through the
  ## add-on switch into ``stateDir``, recording the manifest's deployment
  ## and sequence. An unsupported base is raised through, as the agent
  ## expects (``aoUnsupportedBase``); every other failure is ``ok = false``.
  ## ``agentStateDir`` (the agent's own state) is registered with the
  ## add-on, so an operator rollback pauses this agent (§9.3).
  let run = if apply != nil: apply else: defaultAddonApply()
  result = proc(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.} =
    {.cast(gcsafe).}:
      var text = m.profileText
      var resolved: seq[ProfileBuildAction]
      if resolver != nil and m.profileText.strip().len > 0:
        if not resolver(m.profileText, m.profileFiles, text, resolved):
          return (false, "profile did not compile; see the diagnostic above")
      # A producer's explicit action set wins, as in the plain hook.
      let actions = if m.buildActions.len > 0: m.buildActions else: resolved
      try:
        if agentStateDir.len > 0:
          registerAgentState(stateDir, agentStateDir)
        let r = run(AddonApplyOptions(stateDir: stateDir,
          hostIdentity: hostIdentity, userProfileText: text,
          buildActions: actions, buildActionDispatcher: dispatcher,
          agentRecord: agentRecordOf(m), agentSequence: m.sequence,
          rollbackFloor: m.rollbackFloor))
        if driftSink != nil:
          for d in r.drift: driftSink("apply drift " & d)
        # Below the signed rollback floor a failure keeps the generation
        # (§7.5, A8): the agent reports it, as the apply unit's hook does.
        if r.failedAtFloor.len > 0:
          raise newException(EApplyFailedAtFloor, r.failedAtFloor.join("; "))
        return (true, "add-on generation " & r.generationId &
          (if r.drift.len > 0: "; " & $r.drift.len & " object(s) left as " &
             "actionable drift" else: ""))
      except EAddOnUnsupportedBase, EApplyFailedAtFloor:
        raise
      except AddonRolledBack as e:
        # Attempted, failed its confirmation, reverted (§7.5): the agent's
        # quarantine outcome, as in the apply unit's hook.
        raise newException(EApplyRolledBack, e.msg)
      except CatchableError as e:
        return (false, e.msg)

# ---------------------------------------------------------------------------
# Migration from an agent that applied outside the switch.
# ---------------------------------------------------------------------------

proc legacyAgentGeneration*(legacyStateDir: string): string =
  ## The agent's own current generation, "" when it has none.
  try: readCurrentGenerationId(legacyStateDir)
  except CatchableError: ""

proc needsLegacyMigration*(stateDir, legacyStateDir: string): bool =
  ## The add-on store has never received an agent apply, and the agent's
  ## own state directory holds a generation it applied outside the switch.
  legacyStateDir.len > 0 and
    absolutePath(legacyStateDir) != absolutePath(stateDir) and
    isAddonHost(stateDir) and not anyAgentGeneration(stateDir) and
    legacyAgentGeneration(legacyStateDir).len > 0

proc legacyLastDeployment(legacyStateDir, target: string):
    tuple[sequence: uint64; deploymentId: string] =
  ## The last sequence the legacy agent applied and its deployment id, from
  ## its own records (``<target>.seq`` and the last tick's status).
  let cfg = AgentConfig(target: target, stateDir: legacyStateDir)
  try: result.sequence = readLastAppliedSequence(cfg)
  except CatchableError: discard
  try:
    let j = parseJson(readFile(tickStatusPath(legacyStateDir, target)))
    if j.hasKey("deploymentId") and j.hasKey("sequence") and
        j["sequence"].getBiggestInt() == result.sequence.BiggestInt:
      result.deploymentId = j["deploymentId"].getStr()
  except CatchableError:
    discard

proc migrateLegacyAgentState*(stateDir, legacyStateDir, target,
                              hostIdentity: string;
                              apply: AddonApplyFn = nil): AddonApplyResult =
  ## Commit the profile the legacy agent last applied as an add-on
  ## generation. The objects are the agent's own writes, unchanged since, so
  ## the switch adopts them as they are (spec §4.3, "present, unowned,
  ## identical"): nothing is written and no unit is restarted. An object
  ## that differs, or one generation 0 owns, refuses the switch with nothing
  ## written, and the migration is retried by the next tick.
  let run = if apply != nil: apply else: defaultAddonApply()
  let gen = legacyAgentGeneration(legacyStateDir)
  let env = readGenerationEnvelope(pointerPath(legacyStateDir, gen))
  let last = legacyLastDeployment(legacyStateDir, target)
  run(AddonApplyOptions(stateDir: stateDir, hostIdentity: hostIdentity,
    userProfileText: env.profileText,
    agentSequence: last.sequence,
    agentRecord: AgentRecord(deploymentId: last.deploymentId,
      sequence: last.sequence, migratedFrom: gen)))
