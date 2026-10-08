## Shared-Development-Services L2 — a dev-env ``activity`` takes typed
## constructor parameters, carries an inner ``config:`` block of defaults,
## declares services in its body, and an ``enable`` override reaches the
## configuration those services render.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The declarations are produced by the real ``package`` macro over the
## real fixture recipe, the dev-env body is run by the real
## ``buildPackageDevEnv`` the provider uses, the services are read out of
## the real registry L1's emitter writes, and the rendered configuration
## is read out of the real ``reprobuild.builtin.fs writeText`` build
## action ``renderConfigFile`` registers. A hand-built record would make
## the file vacuous: what is under test is what the MACRO lowers.
##
## Compiled with ``--define:reproProviderMode`` (registered in
## ``scripts/generate_test_edges.nim``'s ``isProviderModePath``) because
## the dev-env ``activity`` surface — ``proc activity(name: string)``,
## ``servicePlaceholder``, ``buildPackageDevEnv`` and the generated
## ``devEnv<Pkg>Package`` proc itself — exists only in that mode.
##
## Governing spec text, ``Package-Model.md`` §"Activity declaration
## shape":
##
## * "Activities are declared with a function-call shape. Required
##   dependencies are constructor-style typed parameters; everything that
##   has a default lives in an inner ``config:`` block."
## * "Required dependencies (``db``, ``assets``) are typed parameters of
##   the activity. The body uses them like ordinary Nim values —
##   ``db.connectionString``, ``assets.bucket`` — with full typechecking
##   and go-to-definition."
## * "A parameterless activity is just ``activity <name>: <body>``."
## * §"Systems And Enable Composition" — "``enable myApi(db = mainDb,
##   assets = assets): <overrides>`` is a typed call into the activity's
##   generated entry point."
##
## THE CONTROL that keeps "the override reached the rendered config" from
## being vacuous is the ``worker`` activity in the fixture: it is enabled
## with NO overrides and its rendered configuration must hold the
## ``config:`` DEFAULT. An implementation that ignored defaults and always
## wrote whatever the last ``enable`` said would satisfy every positive
## assertion here and fail that one.

import std/[strutils, unittest]

import repro_project_dsl

import activity_params_fixtures

proc fixturePackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "fixture package missing: " & name)

let fixture = fixturePackage("activityParamsPkg")

proc devEnvRequest(activity: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "activityParamsPkg.dev-env",
    entryPointBodyHash: "activityParamsPkg.dev-env.v1",
    reason: girExplicitUserRequest,
    arguments: "/tmp/activity-params-fixture-root",
    namespace: "project-activityParamsPkg",
    activity: activity)

proc runDevEnv(activity: string): DevEnvResult =
  ## Run the fixture's dev-env body from a clean slate. The three
  ## registries this clears are append-only by design — a ``when`` arm may
  ## legitimately declare the same service twice — so re-running the body
  ## without clearing them would accumulate, and a count assertion would
  ## then depend on how many earlier cases happened to run.
  resetActivityRegistry()
  resetDslPortServiceState()
  resetBuildActionRegistry()
  buildPackageDevEnv(fixture, devEnvRequest(activity),
    devEnvActivityParamsPkgPackage)

let devEnv = runDevEnv("default")
let activities = registeredActivities("activityParamsPkg")
let services = registeredServices("activityParamsPkg")
let actions = registeredBuildActions()

proc activityNamed(name: string): DslActivityDef =
  for item in activities:
    if item.activityName == name:
      return item
  raise newException(ValueError, "no activity declared named " & name)

proc serviceNamed(name: string): DslServiceDef =
  for svc in services:
    if svc.serviceName == name:
      return svc
  raise newException(ValueError, "no service registered named " & name)

proc renderedText(actionId: string): string =
  ## The bytes ``renderConfigFile`` recorded for one action — read out of
  ## the real build action rather than recomputed, so the assertion is
  ## about what reached the graph.
  for action in actions:
    if action.id == actionId:
      let arg = callArgEncodedValue(action.call, "text")
      if not arg.present:
        raise newException(ValueError,
          "action " & actionId & " has no `text` argument")
      return arg.value
  raise newException(ValueError, "no build action with id " & actionId)

proc configKeyNamed(def: DslActivityDef; name: string): DslActivityConfigDef =
  for key in def.config:
    if key.name == name:
      return key
  raise newException(ValueError,
    "activity " & def.activityName & " has no config key " & name)

suite "L2 — the constructor shape is recorded, and the string form still is":

  test "both surfaces declare activities, and both names are selectable":
    # ``declaredActivities`` is what the dev-env activity gate reads, and
    # it is populated by ONE registry: the constructor form registers its
    # name through the same ``proc activity(name: string)`` the string
    # form calls, rather than keeping a second list of its own.
    check devEnv.declaredActivities == @["default", "api", "worker", "solo"]

  test "three constructor-shaped activities are recorded, in order":
    var names: seq[string] = @[]
    for item in activities:
      names.add(item.activityName)
    check names == @["api", "worker", "solo"]
    check activityNamed("api").packageName == "activityParamsPkg"

  test "a typed parameter records its name and its written type":
    let api = activityNamed("api")
    check api.params.len == 1
    check api.params[0].name == "db"
    check api.params[0].typeRepr == "DemoDb"

  test "the parameterless ident form takes no parameters and no config":
    # ``Package-Model.md``: "A parameterless activity is just ``activity
    # <name>: <body>``." The ident head is what distinguishes it from the
    # string form, which the walker leaves to the proc.
    let solo = activityNamed("solo")
    check solo.params.len == 0
    check solo.config.len == 0

suite "L2 — `config:` records a default, a doc comment, and requiredness":

  test "a key with a default records its type, default text and doc":
    let port = configKeyNamed(activityNamed("api"), "port")
    check port.typeRepr == "int"
    check port.defaultRepr == "8080"
    check port.hasDefault
    check port.description == "TCP port the API server binds."

  test "a key with NO default is recorded as required, not as empty":
    # ``hasDefault`` is the field that keeps ``issuer: string`` apart from
    # ``issuer: string = ""``. Without it the two records are identical
    # and the second reads as required.
    let issuer = configKeyNamed(activityNamed("api"), "issuer")
    check issuer.typeRepr == "string"
    check issuer.defaultRepr == ""
    check not issuer.hasDefault

  test "the keys are recorded in declaration order, after the parameters":
    var names: seq[string] = @[]
    for key in activityNamed("api").config:
      names.add(key.name)
    check names == @["port", "issuer"]

suite "L2 — the body uses a parameter's members as ordinary typed values":

  test "`db.host` reaches a service's args":
    let svc = serviceNamed("api")
    check "--host" in svc.args
    check DemoDbValue.host in svc.args

  test "`db.connectionString` reaches the rendered configuration":
    check renderedText(ApiRenderActionId).contains(
      "url = \"" & DemoDbValue.connectionString & "\"")

suite "L2 — services declared in an activity body are real services":

  test "one service per enabled activity, with a typed executable":
    var names: seq[string] = @[]
    for svc in services:
      names.add(svc.serviceName)
    check names == @["api", "worker", "solo"]
    check serviceNamed("api").executableTyped.kind == sxkArtifact
    check serviceNamed("api").executableTyped.executableName == "apiBin"

  test "the rendered config reaches args as a typed build-output edge":
    # Not as a plain string: the ``args`` token carries the producing
    # action, which is what L1 built and what L3 lifts.
    let svc = serviceNamed("api")
    check svc.typedArgs.len == 6
    check svc.typedArgs[0].kind == svakLiteral
    check svc.typedArgs[1].kind == svakBuildOutput
    check svc.typedArgs[1].value == ApiConfigPath
    check svc.typedArgs[1].producerActionId == ApiRenderActionId
    check svc.typedArgs[1].producerPackage == "activityParamsPkg"

  test "an `on <trigger>:` block inside an activity body is recorded too":
    let svc = serviceNamed("api")
    check svc.triggers.len == 1
    check svc.triggers[0].kind == stkChangeOutput
    check svc.triggers[0].subject == ApiConfigPath
    check svc.triggers[0].producerActionId == ApiRenderActionId
    check svc.triggers[0].actions.len == 1
    check svc.triggers[0].actions[0].kind == stakSendSignal
    check svc.triggers[0].actions[0].argument == "SIGHUP"

  test "`servicePlaceholder` is untouched — L2 is additive":
    check devEnv.services.len == 1
    check devEnv.services[0].name == "legacy-stack"
    check devEnv.services[0].metadata.contains(
      "reprobuild.dev-session.service.v1")
    # And the two lanes stay disjoint: the typed services are not in the
    # dev-env result, and the placeholder is not in the service registry.
    for service in devEnv.services:
      check service.name notin ["api", "worker", "solo"]
    for svc in services:
      check svc.serviceName != "legacy-stack"

suite "L2 — an `enable` override reaches the rendered configuration":

  test "the override wins over the `config:` default":
    let text = renderedText(ApiRenderActionId)
    check text.contains("port = 9090")
    check not text.contains("port = 8080")
    check "9090" in serviceNamed("api").args

  test "and the control: no override renders the DEFAULT":
    # The assertion that makes the one above mean something. Same shape,
    # same `$port` splice, `enable worker(db = DemoDbValue)` with no
    # override body at all.
    let text = renderedText(WorkerRenderActionId)
    check text.contains("port = 7000")
    check "7000" in serviceNamed("worker").args

  test "a required `config:` key takes the enable site's value":
    check renderedText(ApiRenderActionId).contains(
      "issuer = \"" & ApiIssuer & "\"")

suite "L2 — the dev-env activity gate is unchanged":

  test "an unselected activity still gates its placeholder out":
    # The gate reads ``activityRequirements``, which L2 does not touch.
    # Re-running the whole dev-env body with no activity selected must
    # still declare all four names and surface none of the gated
    # placeholder.
    let empty = runDevEnv("")
    check empty.declaredActivities == @["default", "api", "worker", "solo"]
    check empty.services.len == 0
