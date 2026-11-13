## Shared-Development-Services F1 — THE ACTIONS CHANNEL: a build action
## a `devEnv:` body registers reaches the caller, and one nothing
## consumes is an ERROR rather than a silence.
##
## L9's F1 clause is NOT MET for one measured reason: "`DevEnvResult`,
## the record a dev-env entry point returns, has NO actions field
## (`schemaVersion`, `providerArtifactId`, `providerEntryPointId`,
## `providerEntryPointBodyHash`, `projectRoot`, `lockSliceId`,
## `selectedActivities`, `declaredActivities`, `shellOps`,
## `toolRequirements`, `tasks`, `services`, `diagnostics`,
## `evaluationInputs`, `sourceFingerprints`), so an action registered
## while the `devEnv:` body runs reaches nothing." F1's own closing
## sentence names the fix: "an actions channel on the dev-env entry
## point".
##
## This file measures the channel in all three places it has to exist
## for the fix not to be a half-fix:
##
##   * `DevEnvResult.actions` -- the provider's own return;
##   * the PROVIDER WIRE codec, because the provider is a separate
##     process from the CLI;
##   * the ARTIFACT, because a cached dev-env edge is answered from the
##     artifact without re-running the provider. D-SS11 recorded that
##     hop as "NOT optional" for the resolutions, with the reason that
##     applies verbatim here: a provider-wire-only record would report
##     once and then silently never again.
##
## AND THE DETECTABILITY HALF. Carrying the actions without checking
## that anything consumes them would move F1's silent drop one hop
## downstream: the recipe would declare a render, the node would reach
## the caller, nothing would reference the output, and the file would
## again not be where the service expects it. So an action nothing
## consumes is a `dedsError` diagnostic -- which
## `emitDevEnvDiagnostics` prints and returns true for -- and the
## `dssf1Orphan` fixture is the case that proves the check fires.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## Real `package` blocks expanded by the real DSL macro, the real
## `renderConfigFile`, the real `buildPackageDevEnv`, the real provider
## wire codec and the real SSZ artifact codec.

import std/[strutils, unittest]

import repro_project_dsl
import repro_provider_runtime
import repro_dev_env_artifacts

import dssf1_action_fixtures

const FixtureRoot = "/tmp/dssf1-action-fixture-root"

proc pkgDef(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "fixture drift: " & name & " missing")

proc devEnvRequest(pkg: PackageDef): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: pkg.packageName & ".dev-env",
    entryPointBodyHash: pkg.packageName & ".build.v1",
    reason: girExplicitUserRequest,
    arguments: FixtureRoot,
    namespace: "project-" & pkg.packageName,
    activity: "api")

proc devEnvFor(package: string): DevEnvResult =
  clearRegisteredServices(package)
  let pkg = pkgDef(package)
  if package == Dssf1ConsumerName:
    buildPackageDevEnv(pkg, devEnvRequest(pkg), devEnvDssf1ConsumerPackage)
  elif package == Dssf1OrphanName:
    buildPackageDevEnv(pkg, devEnvRequest(pkg), devEnvDssf1OrphanPackage)
  else:
    buildPackageDevEnv(pkg, devEnvRequest(pkg), devEnvDssf1QuietPackage)

proc errorDiagnostics(res: DevEnvResult): seq[string] =
  for diagnostic in res.diagnostics:
    if diagnostic.severity == dedsError:
      result.add(diagnostic.message)

suite "F1: a `devEnv:` body's actions reach DevEnvResult":

  test "a rendered configuration consumed on argv reaches `actions`":
    let res = devEnvFor(Dssf1ConsumerName)
    check res.actions.len == 1
    check res.actions[0].kind == gnkAction
    check res.actions[0].stableName == Dssf1ConsumedActionId
    # The node id is the BUILD lane's own derivation, namespace
    # included, so a caller addresses the same node either lane names.
    check res.actions[0].id.contains(Dssf1ConsumedActionId)
    check res.actions[0].id.startsWith("project-" & Dssf1ConsumerName)
    # The payload is `actionPayload`'s bytes, carried verbatim. Asserted
    # as non-empty and as CONTAINING THE RENDERED PATH, so a payload
    # that was dropped or zeroed cannot satisfy this.
    check res.actions[0].payload.len > 0
    check Dssf1ConsumedPath in res.actions[0].payload

  test "the service still consumes the rendered path on its argv":
    # The other half of the recipe F1 said could not be written. If the
    # path stopped reaching argv, the case above would still pass and
    # the recipe would be broken in the OTHER direction.
    let res = devEnvFor(Dssf1ConsumerName)
    check res.services.len == 1
    check Dssf1ConsumedPath in res.services[0].typedCommand

  test "a dev-env that renders nothing reports NO actions":
    # The control. Without it, every assertion above would pass for an
    # implementation that filled `actions` from some other registry.
    let res = devEnvFor(Dssf1QuietName)
    check res.actions.len == 0
    check errorDiagnostics(res).len == 0

suite "F1: an action PRODUCED AND NEVER CONSUMED is an error, by name":

  test "the orphan render is reported as an error naming the action":
    let res = devEnvFor(Dssf1OrphanName)
    # It is CARRIED -- dropping it would be the old defect with a new
    # name -- and it is also REFUSED.
    check res.actions.len == 1
    check res.actions[0].stableName == Dssf1OrphanActionId
    let errors = errorDiagnostics(res)
    check errors.len == 1
    check Dssf1OrphanActionId in errors[0]
    check Dssf1OrphanName in errors[0]
    check "PRODUCED AND NEVER CONSUMED" in errors[0]

  test "the consuming package reports NO error for the same shape":
    # The discriminator: the check is about CONSUMPTION and not about
    # an action existing. Without this case a guard that errored on
    # every action would pass the case above.
    check errorDiagnostics(devEnvFor(Dssf1ConsumerName)).len == 0

suite "F1: the actions survive the provider wire":

  test "encode/decode of the response round-trips every action field":
    let res = devEnvFor(Dssf1ConsumerName)
    let response = ProviderGraphResponse(kind: pskDevEnvResult, devEnv: res)
    let decoded = decodeProviderResponse(encodeProviderResponse(response))
    check decoded.devEnv.actions.len == res.actions.len
    check decoded.devEnv.actions[0].id == res.actions[0].id
    check decoded.devEnv.actions[0].kind == res.actions[0].kind
    check decoded.devEnv.actions[0].stableName == res.actions[0].stableName
    check decoded.devEnv.actions[0].payload == res.actions[0].payload

suite "F1: the actions survive the ARTIFACT hop, which is not optional":

  test "the artifact carries the action and the SSZ codec round-trips it":
    let artifact = artifactFromDevEnvResult(devEnvFor(Dssf1ConsumerName))
    check artifact.actions.len == 1
    check artifact.actions[0].actionId == Dssf1ConsumedActionId
    check artifact.actions[0].nodeId.contains(Dssf1ConsumedActionId)
    check artifact.actions[0].payload.len > 0
    let decoded = decodeDevEnvArtifact(encodeDevEnvArtifact(artifact))
    check decoded.actions.len == 1
    check decoded.actions[0].actionId == artifact.actions[0].actionId
    check decoded.actions[0].nodeId == artifact.actions[0].nodeId
    check decoded.actions[0].payload == artifact.actions[0].payload

  test "the action is part of the artifact's IDENTITY":
    # A field outside the content id would let two artifacts differing
    # only in their actions share a cache entry, so the second recipe
    # would be served the first's answer -- the silent drop again, via
    # the cache. Measured by recomputing the id with the action
    # removed.
    let artifact = artifactFromDevEnvResult(devEnvFor(Dssf1ConsumerName))
    var stripped = artifact
    stripped.actions = @[]
    # `encodeDevEnvArtifact` recomputes the content id from the whole
    # record, so the two encodings' ids are the comparison. Read back
    # through the decoder so what is compared is what a cache would
    # store and key on.
    let withActions = decodeDevEnvArtifact(encodeDevEnvArtifact(artifact))
    let withoutActions = decodeDevEnvArtifact(encodeDevEnvArtifact(stripped))
    check withActions.actions.len == 1
    check withoutActions.actions.len == 0
    check withActions.artifactId != withoutActions.artifactId

  test "an artifact whose action carries an EMPTY id is refused by name":
    # The codec's own refusal, driven through the real decoder. An
    # action with no id is an edge nothing can address, and reading it
    # as "there is an action here" is how a cached artifact would
    # promise a file it cannot produce.
    var artifact = artifactFromDevEnvResult(devEnvFor(Dssf1ConsumerName))
    artifact.actions[0].actionId = ""
    let bytes = encodeDevEnvArtifact(artifact)
    var message = ""
    try:
      discard decodeDevEnvArtifact(bytes)
    except CatchableError as err:
      message = err.msg
    check message.len > 0
    check "EMPTY id" in message

  test "an artifact whose action carries an EMPTY payload is refused":
    var artifact = artifactFromDevEnvResult(devEnvFor(Dssf1ConsumerName))
    artifact.actions[0].payload = ""
    let bytes = encodeDevEnvArtifact(artifact)
    var message = ""
    try:
      discard decodeDevEnvArtifact(bytes)
    except CatchableError as err:
      message = err.msg
    check message.len > 0
    check "EMPTY payload" in message
    check Dssf1ConsumedActionId in message

suite "F1: the `--json` view shows the actions":

  test "`toJsonInspection` names every action and its payload size":
    # `repro dev-env --json` is the only view an operator has of what a
    # recipe declared; an action invisible there is one nobody can check
    # before `repro up` acts on it.
    let json = toJsonInspection(
      artifactFromDevEnvResult(devEnvFor(Dssf1ConsumerName)))
    check "\"actions\":" in json
    check Dssf1ConsumedActionId in json
    check "\"payloadBytes\":" in json
    # ... and the EMPTY list for a dev-env that rendered nothing, so the
    # key is always present and a reader can tell "no actions" from "an
    # older artifact that had no such field".
    let quiet = toJsonInspection(
      artifactFromDevEnvResult(devEnvFor(Dssf1QuietName)))
    check "\"actions\":[]" in quiet

# ═══════════════════════════════════════════════════════════════════════
# F1's SECOND HALF (§4.8 / D-SS15): THE CONSUMPTION EDGE.
#
# §4.8 closed F1's blocker and said in as many words what it left: "
# Reporting an action is not running it. Nothing in this change makes the
# dev session BUILD the reported edges, so F1's clause is not met by it
# ... the remaining half is for the dev session to order the reported
# actions before the services it launches."
#
# The dev session cannot order what it cannot see. `actions` says WHICH
# actions exist; it does not say which SERVICE each one has to precede,
# so a supervisor reading only that holds two unrelated lists. The
# edge is `DevEnvServiceMetadata.consumedActionIds` / its artifact
# counterpart, and these suites measure it in the same three places the
# actions themselves are measured above -- the provider's return, the
# provider wire and the artifact -- for the same reason D-SS11 gives: a
# cached dev-env edge is answered from the artifact, so an edge that
# lived only on the wire would order on a cold evaluation and silently
# never again.
# ═══════════════════════════════════════════════════════════════════════

suite "F1 second half: the service carries the CONSUMPTION EDGE":

  test "the consuming service names the action's ID, not its path":
    let res = devEnvFor(Dssf1ConsumerName)
    check res.services.len == 1
    check res.services[0].consumedActionIds == @[Dssf1ConsumedActionId]
    # And the id it names is one the SAME result reports as an action, so
    # the two channels address one node rather than two.
    var reported: seq[string] = @[]
    for action in res.actions:
      reported.add(action.stableName)
    check Dssf1ConsumedActionId in reported

  test "a service that consumes nothing carries an EMPTY edge":
    # The control. Without it every assertion above would pass for an
    # implementation that filled the field from the action list.
    let res = devEnvFor(Dssf1QuietName)
    check res.services.len == 1
    check res.services[0].consumedActionIds.len == 0

  test "the ORPHAN package's service carries an empty edge beside a reported action":
    # The discriminator, and the one case that separates "this field
    # records consumption" from "this field lists the actions". The
    # orphan fixture renders a file and references it nowhere: the
    # action IS reported and the service names NOTHING.
    let res = devEnvFor(Dssf1OrphanName)
    check res.actions.len == 1
    check res.actions[0].stableName == Dssf1OrphanActionId
    check res.services.len == 1
    check res.services[0].consumedActionIds.len == 0

  test "the edge survives the provider wire":
    let res = devEnvFor(Dssf1ConsumerName)
    let response = ProviderGraphResponse(kind: pskDevEnvResult, devEnv: res)
    let decoded = decodeProviderResponse(encodeProviderResponse(response))
    check decoded.devEnv.services.len == 1
    check decoded.devEnv.services[0].consumedActionIds ==
      @[Dssf1ConsumedActionId]
    # The fields AFTER it in the record are still read correctly, which
    # is what a positional append has to prove: an offset that shifted
    # would corrupt the neighbours rather than the new field.
    check decoded.devEnv.services[0].name == res.services[0].name
    check decoded.devEnv.services[0].typedCommand ==
      res.services[0].typedCommand

  test "the edge survives the ARTIFACT hop, which is not optional":
    let artifact = artifactFromDevEnvResult(devEnvFor(Dssf1ConsumerName))
    check artifact.services.len == 1
    check artifact.services[0].consumedActionIds ==
      @[Dssf1ConsumedActionId]
    let decoded = decodeDevEnvArtifact(encodeDevEnvArtifact(artifact))
    check decoded.services.len == 1
    check decoded.services[0].consumedActionIds ==
      @[Dssf1ConsumedActionId]
    check decoded.services[0].instanceEnvironment ==
      artifact.services[0].instanceEnvironment

  test "the edge is part of the artifact's IDENTITY":
    # For the reason the actions themselves are: a field outside the
    # content id lets two artifacts that order their actions differently
    # share a cache entry, so the second recipe is served the first's
    # ordering.
    let artifact = artifactFromDevEnvResult(devEnvFor(Dssf1ConsumerName))
    var stripped = artifact
    stripped.services[0].consumedActionIds = @[]
    let withEdge = decodeDevEnvArtifact(encodeDevEnvArtifact(artifact))
    let withoutEdge = decodeDevEnvArtifact(encodeDevEnvArtifact(stripped))
    check withEdge.services[0].consumedActionIds.len == 1
    check withoutEdge.services[0].consumedActionIds.len == 0
    check withEdge.artifactId != withoutEdge.artifactId

  test "`toJsonInspection` shows the edge, and shows it EMPTY when there is none":
    let json = toJsonInspection(
      artifactFromDevEnvResult(devEnvFor(Dssf1ConsumerName)))
    check "\"consumedActionIds\":[\"" & Dssf1ConsumedActionId & "\"]" in json
    let quiet = toJsonInspection(
      artifactFromDevEnvResult(devEnvFor(Dssf1QuietName)))
    check "\"consumedActionIds\":[]" in quiet
