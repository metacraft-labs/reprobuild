## The deploy agent on an add-on host applies through the add-on switch
## (ReproOS Add-On Mode §9, §7.4, §7.5, §9.3), unit level. The VM gate
## ``e2e_addon_agent_generations_and_rollback`` drives the same code through
## real switches; this file pins the decisions that need neither root nor a
## guest:
##
## * the agent record a generation carries (deployment, sequence, the agent
##   generation a migration took over);
## * a rollback pauses every agent registered with the add-on (the deploy
##   agent's own marker), a paused agent's tick reports ``aoPaused`` (exit
##   0) and applies nothing, and resume lifts it;
## * the apply hook hands the add-on switch the add-on's state directory,
##   the manifest's deployment and sequence, its build actions and, when a
##   resolver is given (the full engine), the compiled text;
## * migration runs exactly when the add-on store has no agent generation
##   and the agent's own state directory has one, and switches the profile
##   that agent last applied, recording what it took over.
##
## At reprobuild 3a1068e25b (before this change) the agent's apply on an
## add-on host was the plain `repro infra apply` into its own state
## directory: none of these hooks existed, so this file does not compile
## there.
##
## MOCK JUSTIFICATION. The add-on switch itself is replaced by a recorder
## (``AddonApplyFn``) in the hook and migration cases: a real switch needs
## root, systemd and a bootstrapped host, which the VM gate provides. What
## is tested here is what reaches the switch. The agent tick, the record
## codecs, the generation envelope and the state layout are the production
## ones, on the real filesystem.

import std/[json, os, strutils, tempfiles, unittest]

import repro_deploy_agent
import repro_deploy_agent/apply_hook
import repro_infra
import repro_infra/addon_diagnostics
import repro_peer_cache/auth as peerAuth
import repro_profile
import repro_addon/addon_apply
import repro_addon/agent_record
import repro_addon/agent_switch
import repro_addon/collision
import repro_addon/ledger

type Recorder = ref object
  calls: seq[AddonApplyOptions]
  raiseBase: bool
  fail: string

proc recorder(r: Recorder): AddonApplyFn =
  result = proc(o: AddonApplyOptions): AddonApplyResult {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      r.calls.add(o)
      if r.raiseBase:
        raise newException(EAddOnUnsupportedBase, "base not in the matrix")
      if r.fail.len > 0:
        raise newException(AddonApplyError, r.fail)
      AddonApplyResult(generationId: "gen-" & $r.calls.len)

proc manifest(seq: uint64; dep, text: string;
              actions: seq[ProfileBuildAction] = @[]): DeployManifest =
  DeployManifest(target: "addon-tb", sequence: seq, deploymentId: dep,
    profileText: text, buildActions: actions)

proc fakeAddonHost(stateDir: string) =
  createDir(stateDir)
  writeLedger(ledgerCopyPath(stateDir), Ledger(generation: "", entries: @[]))

suite "the agent record and pausing the agents":
  test "an agent record round-trips and marks its generation":
    let tmp = createTempDir("addon-agent-record-", "")
    defer: removeDir(tmp)
    let r = AgentRecord(deploymentId: "hms-3-be49", sequence: 3,
                        migratedFrom: "66ac8b48")
    check parseAgentRecord(render(r)) == r
    check not anyAgentGeneration(tmp)
    createDir(generationDir(tmp, "g1"))
    writeFile(agentRecordPath(tmp, "g1"), render(r))
    check anyAgentGeneration(tmp)
    check readAgentRecord(tmp, "g1") == r
    check not readAgentRecord(tmp, "g2").present
    expect AgentRecordError:
      discard render(AgentRecord(deploymentId: "a\nb"))

  test "a rollback pauses every agent registered here; resume lifts each":
    let tmp = createTempDir("addon-agent-pause-", "")
    defer: removeDir(tmp)
    let addonState = tmp / "system"
    let agentA = tmp / "agent-a"
    let agentB = tmp / "agent-b"
    registerAgentState(addonState, agentA)
    registerAgentState(addonState, agentB)
    registerAgentState(addonState, agentA)          # idempotent
    check registeredAgentStates(addonState) == @[agentA, agentB]
    check pauseAgents(addonState, "g1", operator = "zahary") ==
      @[agentA, agentB]
    for d in [agentA, agentB]:
      let p = readPauseMarker(d)
      check p.paused and p.generation == "g1" and p.operator == "zahary"
    check resumeAgents(addonState) == @[agentA, agentB]
    check not readPauseMarker(agentA).paused
    check resumeAgents(addonState).len == 0

suite "a paused agent":
  test "a tick of a paused agent reports aoPaused, exit 0, and applies nothing":
    let tmp = createTempDir("addon-agent-paused-", "")
    defer: removeDir(tmp)
    let signer = peerAuth.generateKeypair()
    var m = manifest(2, "d2", "x")
    signManifest(signer, m)
    let enc = encodeManifest(m)
    var bytes = newString(enc.len)
    for i, x in enc: bytes[i] = char(x)
    writeFile(tmp / "m2.rdm", bytes)
    let agentState = tmp / "agent"
    registerAgentState(tmp / "system", agentState)
    discard pauseAgents(tmp / "system", "g1", operator = "zahary")
    var applied = 0
    let cfg = AgentConfig(target: "addon-tb", sources: @[tmp / "m2.rdm"],
      anchors: anchorsFromKeypairs(@[signer.publicKey]),
      stateDir: agentState)
    let deps = AgentDeps(
      apply: proc(m: DeployManifest): tuple[ok: bool; message: string]
          {.gcsafe.} =
        {.cast(gcsafe).}:
          inc applied
          (true, ""))
    let o = runAgentTick(cfg, deps)
    check o.kind == aoPaused
    check "g1" in o.message
    check deployAgentExitCode(o.kind) == 0
    check applied == 0

suite "the agent's apply goes through the add-on switch":
  test "the switch gets the add-on state, the deployment, the sequence and the actions":
    let r = Recorder()
    let action = ProfileBuildAction(id: "llm-api-proxy")
    let tmp = createTempDir("addon-agent-hook-", "")
    defer: removeDir(tmp)
    let hook = addonAgentApplyHook(tmp / "system", "rpi2",
      agentStateDir = tmp / "agent", apply = recorder(r))
    let res = hook(manifest(4, "hms-4-aa", "fs.systemFile {}\n", @[action]))
    check res.ok
    check "gen-1" in res.message
    check r.calls.len == 1
    let o = r.calls[0]
    check o.stateDir == tmp / "system"
    check registeredAgentStates(tmp / "system") == @[tmp / "agent"]
    check o.hostIdentity == "rpi2"
    check o.userProfileText == "fs.systemFile {}\n"
    check o.agentRecord == AgentRecord(deploymentId: "hms-4-aa", sequence: 4)
    check o.buildActions.len == 1 and o.buildActions[0].id == "llm-api-proxy"

  test "the full engine's resolver compiles first; a failed compile applies nothing":
    let r = Recorder()
    let resolver: ProfileResolver = proc(profileText: string;
        profileFiles: seq[ProfileFile]; outText: var string;
        outBuildActions: var seq[ProfileBuildAction]): bool {.gcsafe.} =
      if "bad" in profileText: return false
      outText = "canonical of " & profileText
      outBuildActions = @[ProfileBuildAction(id: "searxng")]
      true
    let hook = addonAgentApplyHook("/s", "h", resolver = resolver,
      apply = recorder(r))
    check hook(manifest(5, "d5", "import repro_profile")).ok
    check r.calls[0].userProfileText == "canonical of import repro_profile"
    check r.calls[0].buildActions[0].id == "searxng"
    check not hook(manifest(6, "d6", "bad profile")).ok
    check r.calls.len == 1

  test "an unsupported base is raised through; any other failure is not ok":
    let r = Recorder(raiseBase: true)
    let hook = addonAgentApplyHook("/s", "h", apply = recorder(r))
    expect EAddOnUnsupportedBase:
      discard hook(manifest(1, "d", "x"))
    let f = Recorder(fail: "an interrupted switch is pending")
    let failing = addonAgentApplyHook("/s", "h", apply = recorder(f))
    let res = failing(manifest(1, "d", "x"))
    check not res.ok and "pending" in res.message

suite "migration of an agent that applied outside the switch":
  test "it runs once, switches the profile that agent last applied, and records it":
    let tmp = createTempDir("addon-agent-migrate-", "")
    defer: removeDir(tmp)
    let addonState = tmp / "system"
    let legacy = tmp / "agent-state"
    check not needsLegacyMigration(addonState, legacy)   # not an add-on host
    fakeAddonHost(addonState)
    check not needsLegacyMigration(addonState, legacy)   # no legacy generation
    # The legacy agent's current generation (what `repro infra apply` into
    # its state directory leaves), its sequence floor and its last tick.
    createDir(legacy)
    writeGenerationEnvelope(pointerPath(legacy, "66ac8b48"),
      GenerationEnvelope(schemaVersion: 2, generationId: "66ac8b48",
        hostIdentity: "rpi2", profileText: "systemd.systemUnit {}\n"))
    writeCurrentGenerationId(legacy, "66ac8b48")
    let cfg = AgentConfig(target: "rpi2", stateDir: legacy)
    writeLastAppliedSequence(cfg, 3)
    createDir(parentDir(tickStatusPath(legacy, "rpi2")))
    writeFile(tickStatusPath(legacy, "rpi2"),
      $(%*{"sequence": 3, "deploymentId": "hms-1-be4958"}))
    check needsLegacyMigration(addonState, legacy)
    check not needsLegacyMigration(addonState, addonState)
    let r = Recorder()
    discard migrateLegacyAgentState(addonState, legacy, "rpi2", "rpi2",
      apply = recorder(r))
    check r.calls.len == 1
    let o = r.calls[0]
    check o.stateDir == addonState
    check o.userProfileText == "systemd.systemUnit {}\n"
    check o.buildActions.len == 0
    check o.agentRecord == AgentRecord(deploymentId: "hms-1-be4958",
      sequence: 3, migratedFrom: "66ac8b48")
    check o.agentSequence == 3 and not o.planOnly
    # `repro system addon migration-plan`: the same switch, plan only.
    discard planLegacyMigration(addonState, legacy, "rpi2", "rpi2",
      apply = recorder(r))
    check r.calls.len == 2 and r.calls[1].planOnly and
      r.calls[1].userProfileText == o.userProfileText and
      r.calls[1].agentRecord == o.agentRecord
    # Once an agent generation is in the add-on store, never again.
    createDir(generationDir(addonState, "g1"))
    writeFile(agentRecordPath(addonState, "g1"), render(o.agentRecord))
    check not needsLegacyMigration(addonState, legacy)

suite "taking over running units restarts none":
  # At reprobuild 4cff209e2e a unit the previous ledger did not know was
  # always a changed definition, so the migration switch restarted every
  # unit the agent had applied (the VM gate's step 1 measured both MainPIDs
  # change). An adopted unit is written by nobody: its definition changes
  # only when systemd has not loaded the bytes on disk yet.
  test "an adopted unit systemd has loaded is unchanged; anything else is a change":
    check not unitFileChanged(true, $cvAdopt, "", "s", false, false)
    check unitFileChanged(true, $cvAdopt, "", "s", false, loadedStale = true)
    check unitFileChanged(true, $cvCreate, "", "s", false, false)
    check unitFileChanged(true, $cvAdopt, "", "s", closureMissing = true,
                          loadedStale = false)
    check not unitFileChanged(false, $cvNoOp, "s", "s", false, false)
    check unitFileChanged(false, $cvNoOp, "a", "s", false, false)
    check unitFileChanged(false, $cvUpdate, "s", "s", false, false)

  test "NeedDaemonReload reads stale unless systemd says no":
    check not unitProvisionFromShow("LoadState=loaded\nNeedDaemonReload=no\n").needDaemonReload
    check unitProvisionFromShow("LoadState=loaded\nNeedDaemonReload=yes\n").needDaemonReload
    check unitProvisionFromShow("LoadState=loaded\n").needDaemonReload
