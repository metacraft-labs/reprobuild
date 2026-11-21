## Shared-Development-Services L9 — "DECLARED ONCE" IS NOW TRUE FOR THE
## WHOLE SERVICE, not only for its identity.
##
## What L8's review left, in its own words: "the `instance` block and
## `readiness` still require a `servicePlaceholder`, so 'declared once'
## is only PARTLY unblocked. L7's literal assignment -- identity, scope
## and interface reaching `DevEnvArtifact.services` -- is discharged; the
## remaining two need a typed setter before a recipe can truly declare a
## shared service once."
##
## This file measures the remaining two, plus the two facts that travel
## with them (`workingDirectory`, `stateDirectory`), through the real
## lowering and the real artifact codec. The companion file
## `repro_cli_support/tests/t_l9_a_typed_service_is_supervised_without_a_
## placeholder.nim` measures what the SUPERVISOR then does with them,
## which is the half that decides whether the gate's clause is met.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## A real `package` block with a real typed `service` block and a real
## `environment` section; the dev-env body is run by the real
## `buildPackageDevEnv`; the artifact is produced by the real
## `toDevEnvArtifact` and round-tripped through the real SSZ codec. The
## claim is about what the real lowering carries, so every stage is the
## real one.
##
## THE CONTROL IS A SECOND SERVICE, not an absence. `ssoProbeless`
## declares none of the four setters, in the same activity, through the
## same emitter. Without it, an implementation that populated the fields
## from a default rather than from the body would pass every positive
## assertion here.

import std/[os, sequtils, strutils, unittest]

import repro_project_dsl
import repro_provider_runtime
import repro_dev_env_artifacts

import l9_declared_once_fixtures

const
  FixtureRoot = "/tmp/l9-declared-once-fixture-root"
  ExternalDomainKey = "l9SsoOwner.sso.externalDomain"
  ExternalSecureKey = "l9SsoOwner.sso.externalSecure"

proc pkgDef(): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == "l9SsoOwner":
      return pkg
  raise newException(ValueError, "fixture drift: l9SsoOwner missing")

proc devEnvRequest(pkg: PackageDef; activity: string):
    ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: pkg.packageName & ".dev-env",
    entryPointBodyHash: pkg.packageName & ".build.v1",
    reason: girExplicitUserRequest,
    arguments: FixtureRoot,
    namespace: "project-" & pkg.packageName,
    activity: activity)

proc devEnvResultFor(activity: string; environment = "development"):
    DevEnvResult =
  clearRegisteredServices("l9SsoOwner")
  # BOTH environment-bound keys are reset before each resolution, and
  # that is a correctness requirement rather than hygiene. `applyEnvironment`
  # writes through `setConfigurable`, whose lane is one flat
  # last-write-wins override table (L5, D-SS6), so applying
  # `development` and then `production` in one process would leave
  # `production` carrying `development`'s `externalSecure = true` -- and
  # the non-composition assertion below would then be measuring process
  # state rather than the recipe.
  resetConfigurable(ExternalDomainKey)
  resetConfigurable(ExternalSecureKey)
  # The environment is applied EXPLICITLY rather than through
  # `REPRO_ENVIRONMENT`, because the selection is read at module-init
  # time (`applySelectedEnvironment` is emitted into the package's
  # expansion) and a test cannot set a variable before its own imports
  # initialise. `applyEnvironment` is the split L5 made for exactly
  # this, and it is the same applier closure the selection path runs.
  if environment.len > 0:
    applyEnvironment("l9SsoOwner", environment)
  let pkg = pkgDef()
  buildPackageDevEnv(pkg, devEnvRequest(pkg, activity),
    devEnvL9SsoOwnerPackage)

proc serviceNamed(res: DevEnvResult; name: string): DevEnvServiceMetadata =
  for svc in res.services:
    if svc.name == name:
      return svc
  raise newException(ValueError, "no service named " & name)

suite "L9: the fixture declares the service ONCE, and that is asserted":

  test "no service record carries placeholder metadata":
    # The control for the whole file. A `servicePlaceholder`'s metadata
    # IS the JSON blob, so an empty `metadata` on every record is what
    # says the typed block is the only channel in play. Without this, a
    # passing assertion below could be reading a placeholder.
    let res = devEnvResultFor("sso")
    check res.services.len == 2
    for svc in res.services:
      checkpoint("service " & svc.name & " carries metadata: " & svc.metadata)
      check svc.metadata.len == 0

  test "the fixture's identity literal and its exported const agree":
    # `identity stable` takes a string LITERAL by design (§4.2), so the
    # fixture cannot splice its own const there. Asserted rather than
    # left to a reader comparing two lines.
    let svc = serviceNamed(devEnvResultFor("sso"), "sso")
    check svc.identityStableId == L9SsoStableId

suite "L9: `readiness` reaches the record":

  test "the declared probe, its path and its timeout all travel":
    let svc = serviceNamed(devEnvResultFor("sso"), "sso")
    check svc.readinessKind == "fileExists"
    check svc.readinessPath == L9ReadyMarker
    check svc.readinessTimeoutMs == int64(L9ReadyTimeoutMs)
    check svc.readinessUrl == ""

  test "a service that declares NO readiness reports UNDECLARED":
    # The distinction `srkUnset` exists for: "" is not "none". A service
    # whose author said nothing must send the supervisor to the
    # placeholder's probe, and one that wrote `readiness none` must not.
    let svc = serviceNamed(devEnvResultFor("sso"), "ssoProbeless")
    check svc.readinessKind == ""
    check svc.readinessPath == ""
    check svc.readinessTimeoutMs == 0

suite "L9: the working directory and the state directories reach the record":

  test "`workingDirectory` travels, and its absence is distinguishable":
    let res = devEnvResultFor("sso")
    check serviceNamed(res, "sso").workingDirectory == "."
    check serviceNamed(res, "ssoProbeless").workingDirectory == ""

  test "`stateDirectory` REPEATS, in declaration order":
    # Repeating is the shape the placeholder's `resources` LIST has, so
    # a second `stateDirectory` must append rather than replace. A
    # last-wins setter would silently drop the first directory, and the
    # supervisor would then not create it.
    let res = devEnvResultFor("sso")
    check serviceNamed(res, "sso").stateDirectories ==
      @[L9StateDir, L9SecondStateDir]
    check serviceNamed(res, "ssoProbeless").stateDirectories.len == 0

suite "L9: the `instance:` block reaches the record":

  test "the block's presence and its lease travel":
    let svc = serviceNamed(devEnvResultFor("sso"), "sso")
    check svc.instanceDeclared
    # D-SS5: `keep`, as the one wire number both lanes read.
    check svc.instanceLeaseTtlSeconds == SharedServiceInstanceKeepTtlSeconds
    check svc.instanceLeaseTtlSeconds == -1

  test "a service with no `instance:` block is SESSION-OWNED":
    let svc = serviceNamed(devEnvResultFor("sso"), "ssoProbeless")
    check not svc.instanceDeclared

  test "the environment component is DERIVED from the selection":
    # §6.4 makes the selection a tracked input and §6.5 makes it part of
    # the instance key. The typed `instance:` block refuses an
    # `environment` setting by name, so this value can only have come
    # from the selection -- which is the property that stops a recipe
    # holding a second, disagreeing answer.
    #
    # BOTH DIRECTIONS, because one of them is vacuous on its own: with
    # nothing selected the derived value and the ground state are both
    # the empty string, so an implementation that never read the
    # selection would pass. The second half sets the variable and
    # measures that the value MOVES.
    let before = selectedEnvironmentName()
    check before.len == 0
    check serviceNamed(devEnvResultFor("sso"), "sso").instanceEnvironment == ""
    putEnv(ReproEnvironmentEnvVar, "development")
    defer: delEnv(ReproEnvironmentEnvVar)
    check selectedEnvironmentName() == "development"
    let svc = serviceNamed(devEnvResultFor("sso"), "sso")
    check svc.instanceEnvironment == "development"
    # And the control service, which declares no `instance:` block at
    # all, stays empty -- so the value is read per DECLARATION rather
    # than stamped onto every record from the process environment.
    check serviceNamed(devEnvResultFor("sso"),
      "ssoProbeless").instanceEnvironment == ""

suite "L9: the environment binds the external identity ONCE":

  test "`development` binds the dev hostname":
    # The TLS half of the binding is NOT asserted here -- `externalSecure`
    # is not on this service's command line at all -- and the case is
    # named for what it measures. It is asserted in `production` does
    # NOT inherit `development`'s `externalSecure` below, which reads
    # that key directly.
    let svc = serviceNamed(devEnvResultFor("sso", "development"), "sso")
    check "--external-domain" in svc.typedCommand
    let idx = svc.typedCommand.find("--external-domain")
    check idx >= 0
    check svc.typedCommand[idx + 1] == L9DevDomain

  test "`production` binds the production hostname over the SAME service":
    # The gate's first clause in one case: one definition, two
    # environments. Nothing about the service changes -- same identity,
    # same scope, same probe -- only the binding.
    let svc = serviceNamed(devEnvResultFor("sso", "production"), "sso")
    let idx = svc.typedCommand.find("--external-domain")
    check idx >= 0
    check svc.typedCommand[idx + 1] == L9ProductionDomain
    check svc.identityStableId == L9SsoStableId
    check svc.scope == "workspace"
    check svc.readinessKind == "fileExists"

  test "`production` does NOT inherit `development`'s bindings":
    # L5's deferral control, re-measured on this fixture: environments
    # do not compose, so a key `production` leaves unbound stays on its
    # DECLARED default. Layering would have handed a production build
    # `externalSecure = true`, which no author wrote for it.
    #
    # Asserted on the CONFIGURABLE rather than on argv, because
    # `externalSecure` is not on this service's command line -- and
    # asserting the domain alone would pass under layering too, since
    # layering replaces the domain as well.
    discard devEnvResultFor("sso", "development")
    check readConfigurable[bool](ExternalSecureKey)
    discard devEnvResultFor("sso", "production")
    checkpoint("`production` leaves `externalSecure` on its declared " &
      "default, which is false")
    check not readConfigurable[bool](ExternalSecureKey)

suite "L9: both products contribute, and NEITHER names a hostname":

  test "both relying parties are present, each attributed":
    let svc = serviceNamed(devEnvResultFor("sso"), "sso")
    check "product-a" in svc.registrationMembers
    check "product-b" in svc.registrationMembers
    var contributors: seq[string] = @[]
    for contributor in svc.registrationContributors:
      if contributor notin contributors:
        contributors.add(contributor)
    check "l9ProductA" in contributors
    check "l9ProductB" in contributors

  test "the consumers' own source text contains no hostname":
    # The gate asserts this by grep over the two PRODUCT repositories;
    # this is the same assertion over the reprobuild-side model of them,
    # so the property has a control that runs in CI rather than only in
    # a milestone's evidence drawer.
    let source = readFile(currentSourcePath().parentDir() /
      "l9_declared_once_fixtures.nim")
    let consumerStart = source.find("package l9ProductA:")
    check consumerStart > 0
    let consumers = source[consumerStart .. ^1]
    check L9DevDomain notin consumers
    check L9ProductionDomain notin consumers
    check "metacraft-labs.test" notin consumers
    check "metacraft-labs.com" notin consumers

suite "L9: every supervision fact survives the artifact codec":

  test "an SSZ round trip preserves all nine fields":
    # THE ENVIRONMENT IS SELECTED FOR THIS CASE, and that is the
    # difference between asserting nine fields and asserting eight.
    # With nothing selected the ninth field is the empty string on both
    # sides of the round trip, so `instanceEnvironment ==
    # selectedEnvironmentName()` would hold for a codec that dropped the
    # field entirely. Pinning it to a NON-EMPTY literal is what makes
    # the case name true.
    putEnv(ReproEnvironmentEnvVar, "development")
    defer: delEnv(ReproEnvironmentEnvVar)
    let artifact = artifactFromDevEnvResult(devEnvResultFor("sso"))
    let decoded = decodeDevEnvArtifact(encodeDevEnvArtifact(artifact))
    var found = false
    for svc in decoded.services:
      if svc.name != "sso":
        continue
      found = true
      check svc.readinessKind == "fileExists"
      check svc.readinessPath == L9ReadyMarker
      check svc.readinessUrl == ""
      check svc.readinessTimeoutMs == int64(L9ReadyTimeoutMs)
      check svc.workingDirectory == "."
      check svc.stateDirectories == @[L9StateDir, L9SecondStateDir]
      check svc.instanceDeclared
      check svc.instanceLeaseTtlSeconds == -1
      check svc.instanceEnvironment == "development"
    check found

  test "the negative lease survives as a NEGATIVE number":
    # `keep` is -1 and the SSZ field is a `uint64`, so the round trip
    # goes through a `cast` rather than a conversion. A conversion would
    # have raised, or -- worse, with range checks off -- delivered
    # 18446744073709551615 as a ttl: a lease that never expires for the
    # wrong reason, which is indistinguishable from `keep` until it is
    # compared.
    let artifact = artifactFromDevEnvResult(devEnvResultFor("sso"))
    let decoded = decodeDevEnvArtifact(encodeDevEnvArtifact(artifact))
    var found = false
    for svc in decoded.services:
      if svc.name == "sso":
        found = true
        check svc.instanceLeaseTtlSeconds < 0
    # Without this the case passes having asserted NOTHING if the
    # fixture's service is ever renamed, which is the sibling case's
    # guard and was missing here.
    check found

  test "the JSON view shows every supervision fact":
    # `repro dev-env --json` is how an operator sees what a recipe
    # declared. A field that reaches the artifact but not this view is
    # invisible at exactly the moment someone is debugging why a session
    # hung waiting for a probe.
    let json = toJsonInspection(artifactFromDevEnvResult(devEnvResultFor("sso")))
    check "\"readinessKind\":\"fileExists\"" in json
    check "\"readinessPath\":\"" & L9ReadyMarker & "\"" in json
    check "\"workingDirectory\":\".\"" in json
    check "\"instanceDeclared\":true" in json
    check "\"instanceLeaseTtlSeconds\":-1" in json
    check L9StateDir in json

  test "the artifact schema version is 6, which is what makes a refusal possible":
    # The fields are appended to a positional codec, so a payload
    # written before they existed would decode with shifted offsets --
    # which is not an error, just wrong values. The version bump is what
    # turns that into a refusal by name.
    #
    # THIS CASE ASSERTS THE VERSION, NOT THE REFUSAL, and the name says
    # so. The refusal itself -- that every superseded envelope version
    # is rejected BY NAME and the next one up is rejected as unknown --
    # is asserted in `tests/unit/t_dev_env_large_values.nim`, which owns
    # the wire-bytes pin. Naming a refusal here that is measured
    # elsewhere is how a reader comes to believe this file proves
    # something it does not.
    #
    # MOVED 3 -> 4 BY D-SS11, which appended
    # `DevEnvArtifact.sharedResolutions`, and 4 -> 5 BY F1, which
    # appended `DevEnvArtifact.actions`, and 5 -> 6 BY F1's second half
    # (`dfacf036b`), which appended
    # `DevEnvServiceSummary.consumedActionIds`. That addition leaves the
    # supervision facts asserted above unchanged. This case is a PIN ON
    # THE NUMBER, so it has to move with the number, and these moves were
    # found by the regression sweep rather than by reading -- which is
    # the argument for the sweep: L9's own version bump broke the same
    # pin in `t_dev_env_large_values` and was found the same way.
    check DevEnvArtifactSchemaVersion == 6'u32
