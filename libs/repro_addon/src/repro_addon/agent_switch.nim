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
## §9 "Migration"); generation-0 objects the profile declares (rpi2's
## caches.conf and deploy-signer anchors) are superseded the same way. The
## next apply then diffs the new manifest against that generation like any
## other. `planLegacyMigration` is the same switch with nothing written.

import std/[json, os, strutils]

import repro_deploy_agent
import repro_deploy_agent/agent_mutations
import repro_deploy_agent/apply_hook
import repro_infra
import repro_infra/addon_diagnostics
import repro_profile

import ./addon_apply
import ./agent_checks
import ./agent_record
import ./static_tree

type
  ManifestCompiler* = proc(m: DeployManifest):
      tuple[ok: bool; canonical, actionsJson, revision, error: string]
      {.closure, gcsafe.}
    ## Compiles a manifest's source profile somewhere other than this
    ## process (``verified_compile.unprivilegedCompile``) and returns what
    ## it emitted, untrusted.
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
                          compiler: ManifestCompiler = nil;
                          dispatcher: BuildActionDispatcher = nil;
                          apply: AddonApplyFn = nil;
                          driftSink: proc(d: string) {.closure, gcsafe.} = nil;
                          unitNames: UnitNamesResolver = systemdUnitNames;
                          legacySecretsDir = ""):
    ApplyHook =
  ## The agent's apply on an add-on host: the manifest's profile through
  ## the add-on switch into ``stateDir``, recording the manifest's
  ## deployment and sequence. An unsupported base is raised through, as the
  ## agent expects (``aoUnsupportedBase``); every other failure is
  ## ``ok = false``. ``agentStateDir`` (the agent's own state) is
  ## registered with the add-on, so an operator rollback pauses this agent
  ## (§9.3).
  ##
  ## The full engine's agent makes every check the add-on agent's apply
  ## unit makes (A8, owner decision B3): a source profile is compiled by
  ## ``compiler`` -- never in this (root) process -- and applied only when
  ## the compile reproduces the signed pin; the compiled profile may not
  ## widen the managed prefixes; no profile may touch the management path;
  ## and every build action is bound to the closure digest the manifest
  ## pins. Freshness, the sequence floor, quarantine and the pause are the
  ## tick's (``requireAttestations``).
  ##
  ## ``legacySecretsDir`` is the full engine's `--secrets-dir`: registered
  ## with the add-on, a hand-written `LoadCredential=` from under it is the
  ## legacy delivery §10.3 accepts.
  let run = if apply != nil: apply else: defaultAddonApply()
  result = proc(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.} =
    {.cast(gcsafe).}:
      var text = m.profileText
      var resolved: seq[ProfileBuildAction]
      let source = not isCanonicalProfileText(m.profileText)
      when not agentMutated("engine-agent-skips-a8"):
        if source:
          if compiler == nil:
            return (false, "the manifest's profile is source and this " &
              "agent has no unprivileged compiler; nothing was written")
          let c = compiler(m)
          if not c.ok:
            return (false, "the profile did not compile: " & c.error)
          let pin = compiledProfileCheck(m, c.canonical, c.actionsJson,
                                         c.revision)
          if pin.len > 0:
            recordCompiledProfileRefusal(m, pin)
            return (false, pin)
          text = c.canonical
          if c.actionsJson.len > 0:
            resolved = to(parseJson(c.actionsJson), seq[ProfileBuildAction])
        var prof: SystemProfile
        try: prof = parseSystemProfile(text)
        except CatchableError as e:
          return (false, "the profile does not parse: " & e.msg)
        let refusal = agentProfileRefusal(m, prof, source, stateDir, unitNames)
        if refusal.len > 0:
          return (false, refusal)
      else:
        if source and compiler != nil:
          let c = compiler(m)
          if not c.ok: return (false, "the profile did not compile: " & c.error)
          text = c.canonical
          if c.actionsJson.len > 0:
            resolved = to(parseJson(c.actionsJson), seq[ProfileBuildAction])
      # A producer's explicit action set wins, as in the plain hook.
      var actions = if m.buildActions.len > 0: m.buildActions else: resolved
      when not agentMutated("engine-agent-skips-a8"):
        let pinned = pinActionsToClosureDigests(m, actions)
        if pinned.refusal.len > 0:
          return (false, "closure digests: " & pinned.refusal &
            "; nothing was written")
        actions = pinned.actions
      try:
        if agentStateDir.len > 0:
          registerAgentState(stateDir, agentStateDir)
        if legacySecretsDir.len > 0:
          registerLegacySecretsDir(stateDir, legacySecretsDir)
        let r = run(AddonApplyOptions(stateDir: stateDir,
          hostIdentity: hostIdentity, userProfileText: text,
          buildActions: actions, buildActionDispatcher: dispatcher,
          agentRecord: agentRecordOf(m), agentSequence: m.sequence,
          rollbackFloor: m.rollbackFloor,
          legacySecretsDirs: (if legacySecretsDir.len > 0: @[legacySecretsDir]
                              else: @[])))
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
      except AddonFailedAtFloor as e:
        # Failed after its flip, not committed, and kept from reverting by
        # the floor (§7.5, A8): the same outcome as a committed failure.
        raise newException(EApplyFailedAtFloor, e.msg)
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

proc migrationOptions(stateDir, legacyStateDir, target,
                      hostIdentity: string;
                      legacySecretsDir = ""): AddonApplyOptions =
  ## The switch a migration runs: the profile the legacy agent's current
  ## generation applied, recorded as that agent's last deployment.
  let gen = legacyAgentGeneration(legacyStateDir)
  if gen.len == 0:
    raise newException(AddonApplyError, legacyStateDir & " holds no " &
      "current agent generation: nothing to migrate")
  let env = readGenerationEnvelope(pointerPath(legacyStateDir, gen))
  let last = legacyLastDeployment(legacyStateDir, target)
  AddonApplyOptions(stateDir: stateDir, hostIdentity: hostIdentity,
    userProfileText: env.profileText,
    agentSequence: last.sequence,
    agentRecord: AgentRecord(deploymentId: last.deploymentId,
      sequence: last.sequence, migratedFrom: gen),
    legacySecretsDirs: (if legacySecretsDir.len > 0: @[legacySecretsDir]
                        else: @[]))

proc migrateLegacyAgentState*(stateDir, legacyStateDir, target,
                              hostIdentity: string;
                              apply: AddonApplyFn = nil;
                              legacySecretsDir = ""): AddonApplyResult =
  ## Commit the profile the legacy agent last applied as an add-on
  ## generation. The objects are the agent's own writes, unchanged since, so
  ## the switch adopts them as they are (spec §4.3, "present, unowned,
  ## identical"): nothing is written and no unit is restarted. An object
  ## that differs refuses the switch with nothing written, and the migration
  ## is retried by the next tick.
  let run = if apply != nil: apply else: defaultAddonApply()
  if legacySecretsDir.len > 0:
    registerLegacySecretsDir(stateDir, legacySecretsDir)
  run(migrationOptions(stateDir, legacyStateDir, target, hostIdentity,
                       legacySecretsDir))

proc planLegacyMigration*(stateDir, legacyStateDir, target,
                          hostIdentity: string;
                          apply: AddonApplyFn = nil;
                          legacySecretsDir = ""): AddonApplyResult =
  ## What the migration would do, decided and reported with nothing written
  ## (``planOnly``): every object it would adopt, write or refuse, and the
  ## service transitions. ``stateDir`` and ``legacyStateDir`` may be copies
  ## of the host's (`repro system addon migration-plan`).
  let run = if apply != nil: apply else: defaultAddonApply()
  # Nothing is registered: a plan writes nothing, the directory is this
  # apply's only.
  var o = migrationOptions(stateDir, legacyStateDir, target, hostIdentity,
                           legacySecretsDir)
  o.planOnly = true
  run(o)
