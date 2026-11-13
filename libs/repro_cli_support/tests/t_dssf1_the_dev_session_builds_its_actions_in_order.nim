## Shared-Development-Services F1 (§4.8 / D-SS15), SECOND HALF — THE DEV
## SESSION BUILDS THE REPORTED ACTIONS, AND EACH ONE IS ORDERED BEFORE
## THE SERVICES THAT NAME ITS OUTPUT.
##
## WHAT WAS ABSENT, in §4.8's own closing paragraph: "Reporting an action
## is not running it. Nothing in this change makes the dev session BUILD
## the reported edges, so F1's clause is not met by it -- what is closed
## is F1's stated blocker ... and the remaining half is for the dev
## session to order the reported actions before the services it
## launches." So after the actions channel landed, F1's original
## measurement still reproduced verbatim: the session came up, the
## rendered path reached the service's argv, and the file was never
## written. An action carried and not run is the same missing file with
## better bookkeeping.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## The action under test is produced by the REAL `renderConfigFile`
## (which registers a real `fs.writeText` edge through the real
## `ReproFs`), encoded by the REAL `actionPayload`, lowered by the REAL
## `lowerGraphAction` -- the same proc `repro build` lowers a `gnkAction`
## node with -- and executed by the REAL `executeBuiltinAction`. The
## assertions read the FILE ON DISK, never the runner's own report.
##
## `runDevSessionSupervisor` is not driven here and that is deliberate:
## the ordering claim is about a PLAN, and asserting it through process
## timing would make a race the measurement.
## `tests/integration/t_dssf1_repro_up_builds_the_rendered_config.nim` is
## the end-to-end half -- there a real `repro up` runs and the CONSUMING
## PROCESS ITSELF copies the file it was handed, so "it existed before
## the service started" is read from the consumer's own view rather than
## from this module's.

import std/[os, strutils, unittest]

import repro_cli_support
import repro_cli_support/dev_session
import repro_dev_env_artifacts
import repro_project_dsl

const
  ConfigRel = "etc/dssf1cli/consumed.yaml"
  ConfigText = "listen: 127.0.0.1:19543\nseeded: true\n"
  SecondRel = "etc/dssf1cli/second.yaml"
  SecondText = "listen: 127.0.0.1:19544\n"
  ConsumerName = "api"
  SecondConsumerName = "worker"
  FixturePackage = "dssf1cli"

proc freshRoot(label: string): string =
  result = getTempDir() / ("dssf1-cli-" & label & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc renderOne(path, text: string): BuildOutput =
  ## One real `renderConfigFile`, against a freshly reset registry, so
  ## the action set under test is exactly what this call registered.
  resetBuildActionRegistry()
  renderConfigFile(path, text, packageName = FixturePackage)

proc summaries(): seq[DevEnvActionSummary] =
  ## The artifact's own action records, built from the REAL registry and
  ## the REAL payload codec -- the same two sources
  ## `artifactFromDevEnvResult` reads.
  for action in registeredBuildActions():
    result.add(DevEnvActionSummary(
      nodeId: "project-" & FixturePackage & ":action:" & action.id,
      actionId: action.id,
      payload: actionPayload(action)))

proc consumer(name: string; actionIds: openArray[string];
              dependsOn: openArray[string] = []): ServiceSpec =
  ServiceSpec(name: name,
    command: @["/bin/sh", "-c", "true"],
    dependsOn: @dependsOn,
    consumedActionIds: @actionIds)

suite "F1 second half: the plan puts every action before its consumer":

  test "one action, one consumer: the action's step comes first":
    let cfg = renderOne(ConfigRel, ConfigText)
    let plan = devSessionStartPlan(summaries(),
      [consumer(ConsumerName, [cfg.actionId])])
    check plan.len == 2
    check plan[0].kind == dsskAction
    check plan[0].action.actionId == cfg.actionId
    check plan[1].kind == dsskService
    check plan[1].service.name == ConsumerName
    # The consuming service is NAMED on the action's step, so a failure
    # can say which service will not start. "An action failed" names the
    # wrong half of the problem.
    check plan[0].consumers == @[ConsumerName]

  test "the action precedes a consumer that is itself ordered behind another service":
    # The point of folding the action edge into the SAME depth-first
    # visit `dependsOn` goes through: a transitive consumer gets its
    # action ahead of both services, with no second rule to state it.
    let cfg = renderOne(ConfigRel, ConfigText)
    let plan = devSessionStartPlan(summaries(), [
      consumer(SecondConsumerName, [cfg.actionId]),
      consumer(ConsumerName, [], [SecondConsumerName])])
    var actionAt = -1
    var workerAt = -1
    var apiAt = -1
    for i, step in plan:
      if step.kind == dsskAction and step.action.actionId == cfg.actionId:
        actionAt = i
      elif step.kind == dsskService and step.service.name == SecondConsumerName:
        workerAt = i
      elif step.kind == dsskService and step.service.name == ConsumerName:
        apiAt = i
    check actionAt >= 0
    check workerAt >= 0
    check apiAt >= 0
    check actionAt < workerAt
    check workerAt < apiAt

  test "an action NO listed service consumes is still planned, and last":
    # §4.8's own direction, restated for this pass: the actions registry
    # holds what every activity body registered while the service list
    # is gated on `--activity`, so dropping an unclaimed action would
    # make what the session builds a function of the selection.
    let cfg = renderOne(ConfigRel, ConfigText)
    let plan = devSessionStartPlan(summaries(), [consumer(ConsumerName, [])])
    check plan.len == 2
    check plan[0].kind == dsskService
    check plan[1].kind == dsskAction
    check plan[1].action.actionId == cfg.actionId
    check plan[1].consumers.len == 0

  test "a service naming an action this artifact does NOT carry is refused BY NAME":
    # The silent-drop guard. Without it, a plumbing regression that
    # dropped `actions` on one hop would leave the service's argv
    # holding a path nothing writes -- which is F1's defect exactly --
    # and the session would start.
    discard renderOne(ConfigRel, ConfigText)
    var message = ""
    try:
      discard devSessionStartPlan(summaries(),
        [consumer(ConsumerName, ["fs-writeText-nothing-registered-this"])])
    except CatchableError as err:
      message = err.msg
    check message.len > 0
    check "fs-writeText-nothing-registered-this" in message
    check ConsumerName in message

  test "two actions sharing one id are refused rather than ordered by position":
    let cfg = renderOne(ConfigRel, ConfigText)
    var doubled = summaries()
    doubled.add(doubled[0])
    var message = ""
    try:
      discard devSessionStartPlan(doubled, [consumer(ConsumerName, [cfg.actionId])])
    except CatchableError as err:
      message = err.msg
    check message.len > 0
    check "share the id" in message
    check cfg.actionId in message

suite "F1 second half: the session WRITES the file, before anything starts":

  test "the rendered file is on disk with the rendered bytes, and was not before":
    let root = freshRoot("writes")
    let cfg = renderOne(ConfigRel, ConfigText)
    let target = root / ConfigRel
    # POSITIVE CONTROL FOR THE EXTRACTION. Before the pass runs the file
    # is absent, so "it is there afterwards" cannot be satisfied by a
    # leftover from another case or by the fixture writing it itself.
    # This is the state F1 measured and reported: the path on argv, no
    # file behind it.
    check not fileExists(target)
    let outcome = buildDevEnvActions(summaries(),
      [consumer(ConsumerName, [cfg.actionId])], root, devEnvActionRunner())
    check outcome.failure == ""
    check outcome.built == @[cfg.actionId]
    check fileExists(target)
    # THE BYTES, not the existence. Compared against the text handed to
    # `renderConfigFile` in this same process, so nothing here can be
    # satisfied by a constant repeated in two files.
    check readFile(target) == ConfigText
    removeDir(root)

  test "two actions are both built, in plan order":
    let root = freshRoot("two")
    resetBuildActionRegistry()
    let first = renderConfigFile(ConfigRel, ConfigText,
      packageName = FixturePackage)
    let second = renderConfigFile(SecondRel, SecondText,
      packageName = FixturePackage)
    let outcome = buildDevEnvActions(summaries(), [
      consumer(ConsumerName, [first.actionId]),
      consumer(SecondConsumerName, [second.actionId])], root,
      devEnvActionRunner())
    check outcome.failure == ""
    check outcome.built.len == 2
    check first.actionId in outcome.built
    check second.actionId in outcome.built
    check readFile(root / ConfigRel) == ConfigText
    check readFile(root / SecondRel) == SecondText
    removeDir(root)

  test "a second pass over unchanged content rewrites nothing and still succeeds":
    # Idempotence, which is the one property this pass needs from the
    # executor given that it does NOT go through the action cache:
    # `bakWriteText` compares the destination's bytes and writes nothing
    # when they already match. Measured on the file's modification time
    # rather than on the runner's report.
    let root = freshRoot("idempotent")
    let cfg = renderOne(ConfigRel, ConfigText)
    let specs = [consumer(ConsumerName, [cfg.actionId])]
    check buildDevEnvActions(summaries(), specs, root,
      devEnvActionRunner()).failure == ""
    let target = root / ConfigRel
    let firstWrite = getLastModificationTime(target)
    check buildDevEnvActions(summaries(), specs, root,
      devEnvActionRunner()).failure == ""
    check getLastModificationTime(target) == firstWrite
    check readFile(target) == ConfigText
    removeDir(root)

suite "F1 second half: a failure NAMES the service that will not start":

  test "an action that cannot write its output fails, naming action and consumer":
    # The destination's parent directory is occupied by a FILE, so the
    # real `bakWriteText` executor's `createDir` really fails. Nothing
    # here simulates a failure.
    let root = freshRoot("blocked")
    createDir(root / "etc")
    writeFile(root / "etc" / "dssf1cli", "I am a file, not a directory\n")
    let cfg = renderOne(ConfigRel, ConfigText)
    let outcome = buildDevEnvActions(summaries(),
      [consumer(ConsumerName, [cfg.actionId])], root, devEnvActionRunner())
    check outcome.failure.len > 0
    check cfg.actionId in outcome.failure
    # THE CONSUMING SERVICE IS NAMED. §4.8's complaint about F1's
    # original defect is that the session came UP with the file missing;
    # a failure that does not say which service is about to start
    # against nothing leaves the reader to work that out.
    check ConsumerName in outcome.failure
    check outcome.built.len == 0
    check not fileExists(root / ConfigRel)
    removeDir(root)

  test "no runner at all is a named refusal, not a silent skip":
    let cfg = renderOne(ConfigRel, ConfigText)
    let outcome = buildDevEnvActions(summaries(),
      [consumer(ConsumerName, [cfg.actionId])], freshRoot("norunner"), nil)
    check outcome.failure.len > 0
    check "action runner" in outcome.failure
    check outcome.built.len == 0

  test "a dev-env that registered NOTHING builds nothing and does not fail":
    # The control for every case above: "no actions were built" has to
    # be a property of nothing being registered rather than of the pass
    # being inert.
    resetBuildActionRegistry()
    let outcome = buildDevEnvActions(summaries(),
      [consumer(ConsumerName, [])], freshRoot("quiet"), devEnvActionRunner())
    check outcome.failure == ""
    check outcome.built.len == 0
