## Shared-Development-Services L5 — the gate's headline clause measured
## on the LOWERED SERVICE rather than on the configurable table:
##
##   "one service definition resolved under two environments yielding
##    two instances with different issuers"
##
## `t_dsl_environment_binds_configurables.nim` measures that the binding
## reaches the CONFIGURABLE. That is necessary and not sufficient: a
## design in which the binding landed in the table and the activity's
## generated entry point still defaulted to the author's literal would
## pass every assertion in that file, and the service would be started
## with the wrong hostname. This file measures the value where it
## matters -- in the typed argv of the service record the provider
## lowers, and in the BYTES of the rendered configuration output -- by
## running the real `buildPackageDevEnv` over the real macro's output.
##
## WHICH DISCRIMINATOR IS LOAD-BEARING. The ARGV STRINGS of the lowered
## `DslServiceDef`, and the rendered config's text. Not an exit code:
## with the `environmentBoundValue` wrapper removed from L2's parameter
## default the module still compiles and still lowers a service -- it
## simply lowers `--domain localhost` -- so the exit code does not move
## and the argv does. That mutation is the before-state the milestone's
## evidence drawer records.
##
## Compiled with `--define:reproProviderMode` (registered in
## `scripts/generate_test_edges.nim`'s `isProviderModePath`) because
## `buildPackageDevEnv` and the generated `devEnv<Pkg>Package` only
## exist in that mode.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## The package is a real `package` block, the dev-env body is run by the
## real `buildPackageDevEnv`, the service records are the ones the real
## emitter appended, and the configuration text is produced by the real
## `renderConfigFile` from the real configurable read.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/types    # Executable, for the artifact slot var

import l5_environment_argv_fixtures

proc pkgDef(): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == "l5ArgvPkg":
      return pkg
  raise newException(ValueError, "fixture drift: l5ArgvPkg missing")

proc devEnvRequest(pkg: PackageDef; activity: string):
    ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: pkg.packageName & ".dev-env",
    entryPointBodyHash: pkg.packageName & ".build.v1",
    reason: girExplicitUserRequest,
    arguments: "/tmp/l5-argv-fixture-root",
    namespace: "project-" & pkg.packageName,
    activity: activity)

proc argvUnder(environment: string): seq[string] =
  ## Resolve the ONE definition under `environment` and return the
  ## lowered service's typed argv.
  ##
  ## `clearRegisteredServices` before each run: `buildPackageDevEnv`
  ## re-runs the dev-env body, which re-records the service, and without
  ## the reset the second resolution would read the first's record.
  ## Resetting makes each call a fresh resolution of the same
  ## definition, which is what "resolved under two environments" means.
  let pkg = pkgDef()
  clearRegisteredServices("l5ArgvPkg")
  for key in ["l5ArgvPkg.issuer", "l5ArgvPkg.sso.externalDomain",
              "l5ArgvPkg.sso.externalSecure"]:
    resetConfigurable(key)
  if environment.len > 0:
    applyEnvironment("l5ArgvPkg", environment)
  discard buildPackageDevEnv(pkg, devEnvRequest(pkg, "sso"),
    devEnvL5ArgvPkgPackage)
  for svc in registeredServices("l5ArgvPkg"):
    if svc.serviceName == "zitadel":
      for arg in svc.typedArgs:
        result.add(arg.value)
      return
  raise newException(ValueError, "no `zitadel` service was lowered")

suite "L5 — the fixture really is one definition, declaring two environments":

  test "the package declares exactly ONE service named `zitadel`":
    var count = 0
    clearRegisteredServices("l5ArgvPkg")
    let pkg = pkgDef()
    discard buildPackageDevEnv(pkg, devEnvRequest(pkg, "sso"),
      devEnvL5ArgvPkgPackage)
    for svc in registeredServices("l5ArgvPkg"):
      if svc.serviceName == "zitadel":
        inc count
    check count == 1

  test "and two environments, both binding the same three configurables":
    check registeredEnvironmentNames("l5ArgvPkg") == @["dev", "production"]
    check environmentOwnedConfigKeys("l5ArgvPkg") ==
      @["l5ArgvPkg.issuer", "l5ArgvPkg.sso.externalDomain",
        "l5ArgvPkg.sso.externalSecure"]

suite "L5 — the bound value reaches the lowered service's argv":

  test "with no environment, the argv carries the AUTHOR's defaults":
    # The control. Without it every assertion below could be reading a
    # literal somebody wrote into the fixture's `args`.
    check argvUnder("") ==
      @["start-from-init", "--domain", "localhost", "--secure", "false"]

  test "under `dev`, the argv carries `dev`'s bindings":
    check argvUnder("dev") ==
      @["start-from-init", "--domain", "login.metacraft-labs.test",
        "--secure", "true"]

  test "under `production`, the SAME definition carries production's":
    check argvUnder("production") ==
      @["start-from-init", "--domain", "login.metacraft-labs.com",
        "--secure", "true"]

  test "the two resolutions differ, and differ only where the bindings do":
    let dev = argvUnder("dev")
    let prod = argvUnder("production")
    check dev != prod
    check dev.len == prod.len
    # Token 0, 1 and 3 are literals in the recipe; 2 and 4 come from
    # configurables. Only 2 may differ here, because both environments
    # bind `externalSecure` to the same value -- which is itself the
    # point: a binding set is not a diff.
    check dev[0] == prod[0]
    check dev[1] == prod[1]
    check dev[2] != prod[2]
    check dev[3] == prod[3]
    check dev[4] == prod[4]

suite "L5 — and reaches the rendered configuration's BYTES":
  ## §6.5's "the digest is taken over a definition already resolved
  ## against one environment's bindings" is about the rendered outputs,
  ## so the issuer has to actually be in them.

  test "the rendered config text differs between the two environments":
    # `renderConfigFile` runs in the `build:` body, which
    # `buildPackageFragment` drives; here the configurable read is
    # exercised directly against the same text template, because the
    # fixture's `build:` body is what produced `argvSsoConfig`.
    resetConfigurable("l5ArgvPkg.issuer")
    check readConfigurable[string]("l5ArgvPkg.issuer") ==
      "http://localhost:8080"
    applyEnvironment("l5ArgvPkg", "dev")
    let devIssuer = readConfigurable[string]("l5ArgvPkg.issuer")
    resetConfigurable("l5ArgvPkg.issuer")
    applyEnvironment("l5ArgvPkg", "production")
    let prodIssuer = readConfigurable[string]("l5ArgvPkg.issuer")
    resetConfigurable("l5ArgvPkg.issuer")
    check devIssuer == "https://login.metacraft-labs.test"
    check prodIssuer == "https://login.metacraft-labs.com"
    check devIssuer != prodIssuer

  test "the rendered text is what the service's config file would carry":
    # The TEXT, assembled exactly as the fixture's `build:` body
    # assembles it, so what is asserted is the bytes a
    # `renderConfigFile` edge would be keyed on. The edge itself, its
    # cache behaviour and the resulting IDENTITY are measured against
    # real files in
    # `libs/repro_resources/tests/t_l5_environment_is_in_the_instance_key.nim`
    # -- this is the half that belongs beside the argv.
    resetConfigurable("l5ArgvPkg.issuer")
    applyEnvironment("l5ArgvPkg", "dev")
    let devText = "issuer = \"" &
      readConfigurable[string]("l5ArgvPkg.issuer") & "\"\n"
    resetConfigurable("l5ArgvPkg.issuer")
    applyEnvironment("l5ArgvPkg", "production")
    let prodText = "issuer = \"" &
      readConfigurable[string]("l5ArgvPkg.issuer") & "\"\n"
    resetConfigurable("l5ArgvPkg.issuer")
    check devText == "issuer = \"https://login.metacraft-labs.test\"\n"
    check prodText == "issuer = \"https://login.metacraft-labs.com\"\n"
    check devText != prodText

## ---------------------------------------------------------------------
## THE HEADLINE PROOF, and the resolution-time refusal beside it.
##
## `l5ReqPkg` is `Shared-Development-Services.md` §6's / §9.1's OWN
## worked shape: `externalDomain: string` declared with NO DEFAULT and
## bound by `environment dev:`. Until this landed the macro REFUSED that
## recipe (`macros_b.nim`'s no-default binding guard), so the spec's own
## example was illegal and every route it left an author -- invent a
## default, or pass the value at `enable` -- is the inlining §6 exists
## to replace.
##
## WHICH DISCRIMINATOR IS LOAD-BEARING HERE. For the headline case it is
## the ARGV STRINGS and the RENDERED CONFIG BYTES, as above: the fixture
## COMPILING is necessary and not sufficient, because an implementation
## that gave the required key a slot and then read the type's ZERO out
## of it would compile the same recipe and lower `--domain ""`. For the
## two refusals it is the MESSAGE TEXT, because the two mean different
## things ("this can never work" vs "this configuration does not work")
## and an exception type alone could not tell them apart.
## ---------------------------------------------------------------------

proc reqPkgDef(): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == "l5ReqPkg":
      return pkg
  raise newException(ValueError, "fixture drift: l5ReqPkg missing")

proc reqRequest(pkg: PackageDef): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: pkg.packageName & ".dev-env",
    entryPointBodyHash: pkg.packageName & ".build.v1",
    reason: girExplicitUserRequest,
    arguments: "/tmp/l5-required-fixture-root",
    namespace: "project-" & pkg.packageName,
    activity: "sso")

proc reqReset() =
  clearRegisteredServices("l5ReqPkg")
  resetBuildActionRegistry()
  for key in ["l5ReqPkg.sso.externalDomain", "l5ReqPkg.sso.externalSecure"]:
    resetConfigurable(key)

proc reqResolve(environment: string):
    tuple[argv: seq[string]; rendered: string] =
  ## Resolve the ONE required-key definition under `environment` and
  ## return the lowered service's typed argv together with the bytes
  ## `renderConfigFile` recorded for its config action.
  let pkg = reqPkgDef()
  reqReset()
  if environment.len > 0:
    applyEnvironment("l5ReqPkg", environment)
  discard buildPackageDevEnv(pkg, reqRequest(pkg), devEnvL5ReqPkgPackage)
  for svc in registeredServices("l5ReqPkg"):
    if svc.serviceName == "zitadel":
      for arg in svc.typedArgs:
        result.argv.add(arg.value)
      break
  if result.argv.len == 0:
    raise newException(ValueError, "no `zitadel` service was lowered")
  for action in registeredBuildActions():
    if action.id == ReqRenderActionId:
      let arg = callArgEncodedValue(action.call, "text")
      if not arg.present:
        raise newException(ValueError,
          "the render action carries no `text` argument")
      result.rendered = arg.value
      return
  raise newException(ValueError,
    "no build action with id " & ReqRenderActionId)

proc reqRefusalMessage(selection: string): string =
  ## Resolve with `selection` SELECTED through the real
  ## `REPRO_ENVIRONMENT` path -- not `applyEnvironment` -- and return
  ## the refusal's message. The selection path is used because the
  ## refusal reports the SELECTED environment, and a test that applied
  ## one by hand would be asserting a sentence about a selection nobody
  ## made.
  let pkg = reqPkgDef()
  reqReset()
  if selection.len > 0:
    putEnv(ReproEnvironmentEnvVar, selection)
    doAssert applySelectedEnvironment("l5ReqPkg") == selection
  else:
    delEnv(ReproEnvironmentEnvVar)
  try:
    discard buildPackageDevEnv(pkg, reqRequest(pkg), devEnvL5ReqPkgPackage)
    result = ""
  except EDslPortUnsatisfiedRequired as err:
    result = err.msg
  finally:
    delEnv(ReproEnvironmentEnvVar)
    reqReset()

suite "L5 — §6's OWN example: a REQUIRED `config:` key bound by an environment":

  test "the fixture declares the key with NO default, and three environments bind around it":
    # Fixture drift guard. If somebody gives `externalDomain` a default
    # every assertion below still passes and none of them is about a
    # required key any more.
    # `registerActivityDeclaration` runs INSIDE the dev-env body, so the
    # registry is empty until the body has run once.
    discard reqResolve("dev")
    var ssoDef: DslActivityDef
    for item in registeredActivities("l5ReqPkg"):
      if item.activityName == "sso":
        ssoDef = item
    check ssoDef.activityName == "sso"
    var required: seq[string] = @[]
    var defaulted: seq[string] = @[]
    for key in ssoDef.config:
      if key.hasDefault: defaulted.add(key.name)
      else: required.add(key.name)
    check required == @["externalDomain"]
    check defaulted == @["externalSecure"]
    check registeredEnvironmentNames("l5ReqPkg") ==
      @["dev", "production", "bare"]

  test "the required key HAS A CONFIGURABLE SLOT, and the slot has no seed":
    # The design in one assertion: "no default" is not "no slot". The
    # refusal this replaced rested on the slot not existing.
    reqReset()
    check isConfigKeyRegistered("l5ReqPkg.sso.externalDomain")
    check configurableIsRequired("l5ReqPkg.sso.externalDomain")
    check not configurableIsSatisfied("l5ReqPkg.sso.externalDomain")
    # And the key WITH a default is registered and already satisfied,
    # which is the control for the two predicates above.
    check isConfigKeyRegistered("l5ReqPkg.sso.externalSecure")
    check not configurableIsRequired("l5ReqPkg.sso.externalSecure")
    check configurableIsSatisfied("l5ReqPkg.sso.externalSecure")

  test "the seed is a SHAPE and not a value: reading the slot directly refuses too":
    # THE SECOND LINE OF DEFENCE, and it needs a case of its own because
    # it is not reachable from any assertion above.
    # `requiredConfigurableValue` pre-checks satisfaction and raises its
    # own routed message, so a mutation that made `dslPortLookup` hand
    # the zero seed back as a value was NOT caught by a single case in
    # this file -- measured, 17 OK / 0 FAILED under that mutation. Every
    # OTHER reader of the lane goes through `dslPortLookup`, so the
    # guard there is what stops `readConfigurable[string]` returning ""
    # for a hostname nobody bound.
    reqReset()
    check not configurableIsSatisfied("l5ReqPkg.sso.externalDomain")
    # The enumeration of unsatisfied required keys, which is the
    # diagnostic surface a resolver (L6/L7) asks "what is still
    # missing?" rather than key-by-key.
    check "l5ReqPkg.sso.externalDomain" in unsatisfiedRequiredConfigKeys()
    check "l5ReqPkg.sso.externalSecure" notin
      unsatisfiedRequiredConfigKeys()
    expect EDslPortUnsatisfiedRequired:
      discard readConfigurable[string]("l5ReqPkg.sso.externalDomain")
    # The FALLBACK-flavoured overload must not substitute either. That
    # silent substitution is why `EDslPortUnsatisfiedRequired` is
    # deliberately NOT a subtype of `EDslPortMissingKey`, which that
    # overload catches and answers with the fallback.
    expect EDslPortUnsatisfiedRequired:
      discard readConfigurable("l5ReqPkg.sso.externalDomain", "fallback")
    # THE CONTROL: the same two reads once the environment has satisfied
    # the key. Without it the two refusals above could be a key that is
    # simply unreadable.
    applyEnvironment("l5ReqPkg", "dev")
    check readConfigurable[string]("l5ReqPkg.sso.externalDomain") ==
      "login.metacraft-labs.test"
    check readConfigurable("l5ReqPkg.sso.externalDomain", "fallback") ==
      "login.metacraft-labs.test"
    check "l5ReqPkg.sso.externalDomain" notin
      unsatisfiedRequiredConfigKeys()
    reqReset()

  test "the environment's binding satisfies the required key, and reaches the ARGV":
    let under = reqResolve("dev")
    check under.argv == @["start-from-init", "--config", ReqConfigPath,
      "--domain", "login.metacraft-labs.test", "--secure", "false"]

  test "and reaches the RENDERED CONFIG's bytes":
    let under = reqResolve("dev")
    check under.rendered ==
      "ExternalDomain: login.metacraft-labs.test\nExternalSecure: false\n"

  test "the SAME definition under `production` carries production's hostname":
    let under = reqResolve("production")
    check under.argv == @["start-from-init", "--config", ReqConfigPath,
      "--domain", "login.metacraft-labs.com", "--secure", "true"]
    check under.rendered ==
      "ExternalDomain: login.metacraft-labs.com\nExternalSecure: true\n"

  test "THE CONTROL: the two resolutions differ ONLY where the bindings do":
    # `externalSecure` is bound by `dev` and NOT by `production`, so it
    # differs for a different reason than `externalDomain` does: one is
    # a required key the environment supplied, the other is a defaulted
    # key one environment overrode. Without this the pair above could
    # be reading two literals.
    let dev = reqResolve("dev")
    let prod = reqResolve("production")
    check dev.argv[4] != prod.argv[4]
    check dev.argv[4] == "login.metacraft-labs.test"
    check prod.argv[4] == "login.metacraft-labs.com"
    check dev.argv[6] == "false"
    check prod.argv[6] == "true"
    check dev.argv[0] == prod.argv[0]
    check dev.argv[2] == prod.argv[2]

suite "L5 — REFUSAL TWO OF TWO: the SELECTED environment leaves a required key unbound":

  test "a selected environment that does not bind it refuses, naming it, the environment and both routes":
    let msg = reqRefusalMessage("bare")
    checkpoint(msg)
    check msg.len > 0
    check msg.contains("required `config:` key `sso.externalDomain`")
    check msg.contains("IS UNSATISFIED")
    check msg.contains("the selected environment `bare` does not bind it")
    # BOTH routes, named.
    check msg.contains("environment <name>: sso.externalDomain = <value>")
    check msg.contains("enable sso(externalDomain = <value>)")
    # And the environments that DO bind it, because "bind it in an
    # environment" is not actionable when the real mistake is having
    # selected the wrong one of three.
    check msg.contains("that DO bind it: dev, production")
    # NOT the expansion refusal's sentence: this one means "this
    # configuration does not work", not "this can never work".
    check not msg.contains("NOTHING CAN EVER SATISFY IT")

  test "with NO environment selected it refuses too, and says so":
    # The other half of the same refusal: §6.4's selection is a tracked
    # input and "none" is a state it has. A required key is unsatisfied
    # there as well, and silence would be the accepted-and-not-there
    # failure this campaign hunts.
    let msg = reqRefusalMessage("")
    checkpoint(msg)
    check msg.contains("NO environment is selected")
    check msg.contains("that DO bind it: dev, production")

  test "THE CONTROL: the same resolution under an environment that DOES bind it does not raise":
    # Proves the refusal is about the binding and not about the fixture.
    let msg = reqRefusalMessage("dev")
    check msg == ""

## ---------------------------------------------------------------------
## THE SHAPE EXPANSION CANNOT DECIDE. `l5RefuseUnsatisfiableRequiredKeys`
## decides a POSITIONAL `enable` argument by ARITY -- the argument at
## call-argument-list index `i` binds the parameter at index `i` -- and
## one shape defeats that: a `varargs` constructor parameter, which
## matches GREEDILY, so every later parameter's position moves with the
## argument count. Measured: for
## `g2(extras: varargs[string], a = "A", b = "B")`, `g2("x", "y")` binds
## `"y"` to **b** and leaves `a` at its default, so an index rule is
## wrong in both directions there.
##
## `l5VarargsPkg` is that shape with NOTHING satisfying its required
## key, and it COMPILES (asserted out-of-process in
## `dsl_port/t_dsl_environment_surface_is_typed.nim`). So the question
## this suite answers is the one that matters: does the value then go
## missing in silence? It must not -- the resolution-time refusal is
## what covers the gap, and that is why the expansion skip is a
## narrowing and not a hole.
## ---------------------------------------------------------------------

proc varargsPkgDef(): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == "l5VarargsPkg":
      return pkg
  raise newException(ValueError, "fixture drift: l5VarargsPkg missing")

proc varargsRefusalMessage(): string =
  ## Resolve `l5VarargsPkg` with no environment selected -- it declares
  ## none -- and return the refusal's message, or "" if none was raised.
  let pkg = varargsPkgDef()
  clearRegisteredServices("l5VarargsPkg")
  resetConfigurable("l5VarargsPkg.sso.externalDomain")
  delEnv(ReproEnvironmentEnvVar)
  try:
    discard buildPackageDevEnv(pkg, ProviderGraphRequest(
      kind: prkGraphInvocation,
      providerArtifactId: "test-provider",
      entryPointId: "l5VarargsPkg.dev-env",
      entryPointBodyHash: "l5VarargsPkg.build.v1",
      reason: girExplicitUserRequest,
      arguments: "/tmp/l5-varargs-fixture-root",
      namespace: "project-l5VarargsPkg",
      activity: "sso"), devEnvL5VarargsPkgPackage)
    result = ""
  except EDslPortUnsatisfiedRequired as err:
    result = err.msg
  finally:
    clearRegisteredServices("l5VarargsPkg")
    resetConfigurable("l5VarargsPkg.sso.externalDomain")

suite "L5 — the `varargs` shape expansion cannot decide is still caught at RESOLUTION":

  test "the fixture really is the undecidable shape: a required key behind a `varargs` parameter":
    # Fixture drift guard. If somebody gives `externalDomain` a default,
    # or drops the `varargs` parameter, the assertion below stops being
    # about the gap it exists to cover.
    discard varargsRefusalMessage()
    var ssoDef: DslActivityDef
    for item in registeredActivities("l5VarargsPkg"):
      if item.activityName == "sso":
        ssoDef = item
    check ssoDef.activityName == "sso"
    var required: seq[string] = @[]
    for key in ssoDef.config:
      if not key.hasDefault: required.add(key.name)
    check required == @["externalDomain"]
    # And the package declares NO environment, so expansion's silence
    # here can only be the varargs skip.
    check registeredEnvironmentNames("l5VarargsPkg").len == 0

  test "resolution REFUSES it, naming the key and both routes":
    # THE WHOLE POINT OF THE SKIP BEING A NARROWING AND NOT A HOLE.
    let msg = varargsRefusalMessage()
    checkpoint(msg)
    check msg.len > 0
    check msg.contains("required `config:` key `sso.externalDomain`")
    check msg.contains("IS UNSATISFIED")
    check msg.contains("NO environment is selected")
    check msg.contains("No environment of package `l5VarargsPkg` binds it.")
    check msg.contains("environment <name>: sso.externalDomain = <value>")
    check msg.contains("enable sso(externalDomain = <value>)")
    # The EXPANSION refusal's sentence stays absent: a reader has to be
    # able to tell which of the two failures they have.
    check not msg.contains("NOTHING CAN EVER SATISFY IT")

  test "THE CONTROL: once something satisfies the key, the same resolution does not raise":
    # Proves the refusal is about the key being unsatisfied and not
    # about the fixture being unresolvable for some other reason.
    clearRegisteredServices("l5VarargsPkg")
    setConfigurable("l5VarargsPkg.sso.externalDomain", "login.varargs.test")
    var raised = false
    try:
      discard buildPackageDevEnv(varargsPkgDef(), ProviderGraphRequest(
        kind: prkGraphInvocation,
        providerArtifactId: "test-provider",
        entryPointId: "l5VarargsPkg.dev-env",
        entryPointBodyHash: "l5VarargsPkg.build.v1",
        reason: girExplicitUserRequest,
        arguments: "/tmp/l5-varargs-fixture-root",
        namespace: "project-l5VarargsPkg",
        activity: "sso"), devEnvL5VarargsPkgPackage)
    except EDslPortUnsatisfiedRequired:
      raised = true
    check not raised
    var argv: seq[string] = @[]
    for svc in registeredServices("l5VarargsPkg"):
      if svc.serviceName == "zitadel":
        for arg in svc.typedArgs:
          argv.add(arg.value)
    check argv == @["start-from-init", "--domain", "login.varargs.test"]
    resetConfigurable("l5VarargsPkg.sso.externalDomain")
    clearRegisteredServices("l5VarargsPkg")
