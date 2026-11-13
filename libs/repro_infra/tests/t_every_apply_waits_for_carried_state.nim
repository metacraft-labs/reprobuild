## Every system-scope apply entry point refuses, before anything is
## written, while carried state that its profile can reach is not restored
## on this host (ReproOS Add-On Mode §11.1, "The apply waits for it";
## ``repro_infra/carried_state``):
##
## - ``runInfraApply`` -- the library behind ``repro infra apply``, ``repro
##   system sync`` and the engine's deploy agent;
## - ``runSystemRollback`` -- ``repro system rollback`` on a host realised
##   in full, whose re-apply of an older generation reaches it too.
##
## (The add-on's ``runAddonApply`` -- operator applies, adopt, the add-on
## rollback and agent -- is tested in ``t_addon_state_sets``; ``repro
## system sync`` on a converted guest in the VM gate
## ``e2e_addon_to_reproos_conversion_keeps_state``.)
##
## Falsifying mutation: ``apply-ignores-carried-state``
## (``scripts/run_addon_unit_mutation.sh t_every_apply_waits_for_carried_state
## apply-ignores-carried-state``) turns both cases red.
##
## No mocks: the real apply and rollback, over a real state directory and
## a hand-written carried-state manifest under a temporary root. The
## profiles hold one unit confined to the carried directory, which the
## refusal must stop before it is ever written (the test is not root and
## would fail to write it).

import std/[os, strutils, tempfiles, unittest]

import repro_infra

const
  Host = "carried-state-test-host"
  UnitProfile = """systemd.systemUnit {
  name = "app.service"
  content = "[Service]
ProtectSystem=strict
ReadWritePaths=/var/lib/app
ExecStart=/bin/true
"
}
"""

proc manifestIn(dir: string) =
  createDir(dir)
  writeFile(dir / ManifestFileName, """{"schema":"repro-state-set/1",
"host":"src","createdAt":"x","entries":[{"path":"/var/lib/app",
"disposition":"carry","units":["app.service"],"digest":"sha256:""" &
    repeat('0', 64) & """","archive":"carry-x.rsa","archiveSha256":"""" &
    repeat('0', 64) & """","owners":{}}]}""")

proc options(stateDir, carried, root: string): ApplyOptions =
  result.stateDir = stateDir
  result.hostIdentity = Host
  result.reproExe = "/usr/bin/false"
  result.elevationMode = emNoElevate
  result.noPreview = true
  result.carriedStateDir = carried
  result.carriedStateRoot = root

suite "every apply waits for carried state":
  test "runInfraApply refuses before anything is written":
    let tmp = createTempDir("carried-apply-", "")
    defer: removeDir(tmp)
    manifestIn(tmp / "carried")
    createDir(tmp / "root")
    var why = ""
    try:
      discard runInfraApply(UnitProfile,
        options(tmp / "state", tmp / "carried", tmp / "root"))
    except ECarriedStatePending as e:
      why = e.msg
    check "/var/lib/app (systemUnit:app.service" in why
    check readCurrentGenerationId(tmp / "state").len == 0

  test "runSystemRollback refuses to re-apply a generation that reaches it":
    let tmp = createTempDir("carried-rollback-", "")
    defer: removeDir(tmp)
    let state = tmp / "state"
    createDir(tmp / "root")
    # Two generations of the empty profile, with no carried state yet.
    let first = runInfraApply("", options(state, tmp / "none", tmp / "root"))
    discard runInfraApply("", options(state, tmp / "none", tmp / "root"))
    # The older one now names the unit (what a rollback re-applies).
    var env = readGenerationEnvelope(pointerPath(state, first.generationId))
    env.profileText = UnitProfile
    writeGenerationEnvelope(pointerPath(state, first.generationId), env)
    let active = readCurrentGenerationId(state)
    manifestIn(tmp / "carried")
    var why = ""
    try:
      discard runSystemRollback(SystemRollbackOptions(stateDir: state,
        hostIdentity: Host, reproExe: "/usr/bin/false",
        targetGenerationId: first.generationId,
        carriedStateDir: tmp / "carried", carriedStateRoot: tmp / "root"))
    except ECarriedStatePending as e:
      why = e.msg
    check "/var/lib/app (systemUnit:app.service" in why
    check readCurrentGenerationId(state) == active

suite "a full apply removes the drop-ins it no longer declares (round 5)":
  test "an earlier generation's drop-in is planned as a destroy":
    let tmp = createTempDir("carried-undeclared-", "")
    defer: removeDir(tmp)
    let state = tmp / "state"
    createDir(tmp / "root")
    let first = runInfraApply("", options(state, tmp / "none", tmp / "root"))
    # The active generation declared a drop-in (as an earlier apply would
    # have: the carried-state requirement among them).
    const DropIn = """systemd.systemDropIn {
  unit = "a13r5-undeclared.service"
  name = "state-restore"
  content = "[Unit]
Requires=repro-state-restore.service
"
}
"""
    var env = readGenerationEnvelope(pointerPath(state, first.generationId))
    env.profileText = DropIn
    writeGenerationEnvelope(pointerPath(state, first.generationId), env)
    # Control: a profile that still declares it removes nothing.
    check undeclaredDropIns(state, DropIn).len == 0
    let gone = undeclaredDropIns(state, "")
    check gone.len == 1 and gone[0].kind == srkSystemdSystemDropIn and
      gone[0].diUnit == "a13r5-undeclared.service"
    let plan = producePlan("", Host,
      opts = PlannerOptions(stateDir: state, destroyResources: gone))
    var planned = ""
    for rec in plan.envelope.operations:
      if rec.address == gone[0].address: planned = rec.action
    # Absent on this host, so the destroy is a no-op; planned either way.
    check planned in ["destroy", "no-op"]
