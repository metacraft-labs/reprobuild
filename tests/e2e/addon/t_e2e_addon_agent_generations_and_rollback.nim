## Gate ``e2e_addon_agent_generations_and_rollback`` (spec §7.4, §7.5, §9,
## §9.3; reprobuild-pm issue
## 2026-10-31-addon-deploy-agent-applies-bypass-the-addon-switch-so-rollback-cannot-reach-them).
##
## The deploy agent on an add-on host applies through the add-on switch:
##
## 1. *migration restarts nothing* (c). The guest is put in the state the
##    rpi2 dogfood host was in: an agent that applied outside the switch
##    (its generation and sequence floor in /var/lib/repro/agent/state, its
##    units written and running, unknown to the add-on ledger) and only
##    generation 0 in /var/lib/repro/system. The first tick of the new
##    binary takes it over: an add-on generation records the agent
##    generation it migrated, and neither unit is restarted (same MainPID,
##    same ActiveEnterTimestamp).
## 2. *an agent apply commits an add-on generation* (a). Manifest 2 changes
##    one unit. The tick commits a generation under /var/lib/repro/system
##    whose ``addon-agent`` record carries the manifest's deploymentId and
##    sequence; the changed unit runs the new content, the unchanged one was
##    not restarted.
## 3. *a rollback re-applies and pauses the agent* (b, d). `repro system
##    rollback` to the migrated generation brings the old content back,
##    leaves the unchanged unit running untouched, and writes the pause
##    marker; the next tick reports ``aoPaused`` (exit 0) and changes
##    nothing.
## 4. *rolling forward again* (d) to manifest 2's generation also leaves the
##    unchanged unit untouched; `repro system addon resume` clears the
##    pause, and the next tick converges.
##
## At reprobuild 3a1068e25b, before the change, step 1 committed no add-on
## generation (the tick reported aoConverged and did nothing), step 2's
## generation carried no agent record, and step 3 wrote no pause marker:
## the gate is red there at the first assertion of each step.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``. *Mocking.* None: real guests, the
## static add-on binary, manifests signed with the deploy agent's own code.

import std/[json, os, strutils, times, unittest]

import repro_deploy_agent
import repro_infra
import repro_test_support/reasoned_skip

import ./addon_testbed
import ./addon_secrets_support

const Target = "addon-tb"

proc unitText(name, marker: string): string =
  ## The bytes `renderedSystemUnitContent` gives a unit with no closure and
  ## no credentials: its content, verbatim.
  "[Unit]\nDescription=" & marker & "\n\n[Service]\nExecStart=/bin/sleep " &
    "infinity\n\n[Install]\nWantedBy=multi-user.target\n"

proc unitResource(name, marker: string): string =
  "systemd.systemUnit {\n  name = \"" & name & ".service\"\n  content = \"" &
    unitText(name, marker) & "\"\n}\n\n"

proc profile(changeMarker: string): string =
  unitResource("keep-svc", "keep") & unitResource("change-svc", changeMarker)

proc unitState(g: Guest; unit: string): string =
  ## MainPID and when the unit last became active: both change on a
  ## restart, neither on a no-op.
  g.run("systemctl show -p MainPID -p ActiveEnterTimestampMonotonic " &
        "--value " & unit & ".service").strip().replace("\n", " ")

proc currentGeneration(g: Guest): string =
  extractFilename(g.run("readlink /var/lib/repro/system/current").strip())

proc agentRecordOf(g: Guest; gen: string): string =
  g.exec("cat /var/lib/repro/system/generations/" & gen & "/addon-agent").stdout

proc fakeLegacyAgent(g: Guest; text: string) =
  ## What rpi2's agent left behind when it applied with `repro infra apply`
  ## into its own state directory: the units written and running, and its
  ## generation, sequence floor and last tick in /var/lib/repro/agent/state.
  for (name, marker) in [("keep-svc", "keep"), ("change-svc", "v1")]:
    writeFile(g.runDir / (name & ".service"), unitText(name, marker))
    g.copyTo(g.runDir / (name & ".service"),
             "/etc/systemd/system/" & name & ".service")
  discard g.run("systemctl daemon-reload && systemctl enable --now " &
                "keep-svc.service change-svc.service")
  let legacy = g.runDir / "legacy-state"
  removeDir(legacy)
  createDir(legacy)
  writeGenerationEnvelope(pointerPath(legacy, "legacy0001"),
    GenerationEnvelope(schemaVersion: 2, generationId: "legacy0001",
      activationTimestamp: getTime().toUnix(), hostIdentity: "addon-tb",
      profileText: text))
  let seqDir = "/var/lib/repro/agent/state/deploy-agent"
  discard g.run("mkdir -p /var/lib/repro/agent/state/generations/legacy0001 " &
                seqDir)
  g.copyTo(pointerPath(legacy, "legacy0001"),
    "/var/lib/repro/agent/state/generations/legacy0001/" &
    extractFilename(pointerPath(legacy, "legacy0001")))
  discard g.run("ln -sfn generations/legacy0001 /var/lib/repro/agent/state/current")
  discard g.run("printf '1\\n' > " & seqDir & "/" & Target & ".seq")
  discard g.run("printf '%s' '" & $(%*{"sequence": 1,
    "deploymentId": "legacy-1"}) & "' > " &
    tickStatusPath("/var/lib/repro/agent/state", Target))

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let (ok, anchors) = g.bootstrapAddonWithAnchors(repro, step)
    if not ok: return fails
    let signer = anchors.deploySignerKeys[0]
    let gen0 = g.currentGeneration()
    # 1. Migration (c).
    g.fakeLegacyAgent(profile("v1"))
    let keep0 = g.unitState("keep-svc")
    let change0 = g.unitState("change-svc")
    let m1 = g.publishManifest(signer, Target, 1, profile("v1"), @[], "")
    var r = g.tick(repro, Target, @[m1])
    let genMigrated = g.currentGeneration()
    let rec1 = g.agentRecordOf(genMigrated)
    step("the first tick migrates the agent into an add-on generation",
         r.exitCode == 0 and genMigrated != gen0 and
         "migrated-from\tlegacy0001" in rec1 and "sequence\t1" in rec1 and
         "deployment\tlegacy-1" in rec1, r.stdout & r.stderr & rec1)
    step("the migration restarted neither unit",
         g.unitState("keep-svc") == keep0 and g.unitState("change-svc") == change0,
         keep0 & " / " & g.unitState("keep-svc") & " ; " & change0 & " / " &
         g.unitState("change-svc"))
    # 2. An agent apply commits an add-on generation (a).
    let keep1 = g.unitState("keep-svc")
    let m2 = g.publishManifest(signer, Target, 2, profile("v2"), @[], "")
    r = g.tick(repro, Target, @[m2])
    let gen2 = g.currentGeneration()
    let rec2 = g.agentRecordOf(gen2)
    step("tick 2 commits an add-on generation with deployment and sequence",
         r.outcomeOf() == "aoApplied" and gen2 != genMigrated and
         "deployment\ta7-2" in rec2 and "sequence\t2" in rec2,
         r.stdout & r.stderr & rec2)
    step("the changed unit runs the new content; the other was not restarted",
         "v2" in g.run("systemctl show -p Description --value change-svc.service") and
         g.unitState("keep-svc") == keep1,
         keep1 & " / " & g.unitState("keep-svc"))
    # 3. Rollback re-applies the migrated generation and pauses (b, d).
    r = g.exec(repro & " system rollback " & genMigrated, timeoutSec = 1200)
    step("rollback to the migrated generation succeeds", r.exitCode == 0,
         r.stdout & r.stderr)
    step("after the rollback change-svc runs the old content, keep-svc untouched",
         "v1" in g.run("systemctl show -p Description --value change-svc.service") and
         g.unitState("keep-svc") == keep1, g.unitState("keep-svc"))
    let pause = g.exec("cat /var/lib/repro/agent/state/deploy-agent/pause")
    step("the rollback wrote the pause marker naming the generation",
         pause.exitCode == 0 and genMigrated in pause.stdout, pause.stdout & pause.stderr)
    let genRolled = g.currentGeneration()
    r = g.tick(repro, Target, @[m2])
    step("the next tick is paused (exit 0) and changes nothing",
         r.exitCode == 0 and r.outcomeOf() == "aoPaused" and
         g.currentGeneration() == genRolled and
         "v1" in g.run("systemctl show -p Description --value change-svc.service"),
         r.stdout & r.stderr)
    # 4. Forward again (d), then resume.
    r = g.exec(repro & " system rollback " & gen2, timeoutSec = 1200)
    step("rolling forward to generation 2 leaves keep-svc untouched",
         r.exitCode == 0 and g.unitState("keep-svc") == keep1 and
         "v2" in g.run("systemctl show -p Description --value change-svc.service"),
         r.stdout & r.stderr & g.unitState("keep-svc"))
    r = g.exec(repro & " system addon resume")
    step("resume clears the pause", r.exitCode == 0 and
         g.exec("test ! -e /var/lib/repro/agent/state/deploy-agent/pause").exitCode == 0,
         r.stdout & r.stderr)
    r = g.tick(repro, Target, @[m2])
    step("after resume the tick converges",
         r.outcomeOf() in ["aoConverged", "aoApplied"], r.stdout & r.stderr)
  except CatchableError as e:
    fails.add(b.name & ": raised: " & e.msg)
  finally:
    record["steps"] = steps
    if g != nil: g.destroy()
  fails

suite "e2e_addon_agent_generations_and_rollback":
  test "agent applies are add-on generations; rollback reaches them and pauses the agent":
    if not gatesEnabled():
      skip("REPRO_ADDON_VM_GATES is not 1: this gate boots guests")
    else:
      var all: seq[string]
      let record = %*{"gate": "e2e_addon_agent_generations_and_rollback",
                      "reprobuild": gitHead(), "gosti": gostiHead(),
                      "bases": newJObject()}
      for b in selectedBases():
        let r = newJObject()
        all.add(runBase(b, r))
        record["bases"][b.name] = r
      discard writeRecord("e2e_addon_agent_generations_and_rollback", record)
      for f in all: echo f
      check all.len == 0
