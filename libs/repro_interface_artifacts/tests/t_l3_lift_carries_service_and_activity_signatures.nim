## Shared-Development-Services L3 — the interface lift carries each
## exported service and activity, and the interface fingerprint
## DISCRIMINATES: a signature change moves it, an unrelated change does
## not.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The producers are real ``package`` blocks in ``l3_lift_fixtures.nim``,
## expanded by the real DSL macro; the records read here are the ones the
## macro emitted, and the fingerprints are the real
## ``interfaceFingerprint`` over the real codec.
##
## Governing text:
##
## * ``Shared-Development-Services.md`` §3 — "the member set a consumer
##   compiles against is emitted by the producer's interface artifact,
##   the **interface fingerprint** gates rebuilds, and a signature change
##   re-lifts, re-fingerprints and invalidates consumers". And what the
##   lift must carry: "the service's name, the type of its handle and
##   that type's members … and its ``config:`` surface with defaults so a
##   consumer's ``enable`` block typechecks".
## * ``Typed-Extension-Interfaces-And-Provider-Libraries.md`` §2 —
##   "**Services and activities are a third case for the same lift**".
## * L3 ``:gate:`` — "a change to A's service signature re-lifting,
##   re-fingerprinting and invalidating B (B rebuilds; an unrelated
##   change to A does not)".
##
## WHICH DISCRIMINATOR IS LOAD-BEARING, PER SUITE. The payload suites
## read fields that do not exist before this change (``publicServices``,
## ``publicActivities``), so they do not compile at the base — the
## compile IS the discriminator and is stated as such where it applies.
## The fingerprint suites are the interesting ones: before this change
## ALL THREE fixtures lift to the SAME fingerprint, because no part of a
## dev-env service or activity reached ``ProjectInterface`` at all. So
## the "unrelated change does not move it" assertion passes at the base
## and the "signature change moves it" assertion fails there — only the
## second direction discriminates, and only it is claimed to.

import std/[strutils, unittest]

import repro_project_dsl
import repro_interface_artifacts

import ./l3_lift_fixtures

proc packageDefNamed(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError,
    "fixture drift: no package named " & name & " is registered")

proc liftedInterface(name: string): ProjectInterface =
  toProjectInterface(packageDefNamed(name))

proc namesNormalised(name: string): ProjectInterface =
  ## The lifted interface with every PACKAGE-DERIVED name replaced by a
  ## constant: ``projectName``, ``packageName``, and the generated handle
  ## type names (which are ``<Title>Package<Activity>Handle`` and
  ## therefore carry the package name inside them).
  ##
  ## This normalisation is the whole of what is applied anywhere in this
  ## file, and it is forced rather than chosen. The scenario L3's gate
  ## describes is ONE package edited between two revisions, where the
  ## package name and so the handle type names are identical on both
  ## sides and the only thing that can differ is what the author
  ## changed. Three fixture packages cannot share a name inside one
  ## module, so the artifice has to be undone here or every pair would
  ## differ and the comparison would say nothing.
  ##
  ## Nothing else is normalised, and that is what makes the negative
  ## direction meaningful: the fixtures carry no executables, libraries,
  ## resources or tool uses, so after this the services and activities
  ## are the only thing left that can move the digest.
  result = liftedInterface(name)
  result.projectName = "fingerprint-comparison"
  result.packageName = "fingerprint-comparison"
  for act in result.publicActivities.mitems:
    act.handleType = "NormalisedHandle_" & act.name
  for svc in result.publicServices.mitems:
    if svc.handleType.len > 0:
      svc.handleType = "NormalisedHandle_" & svc.activityName

proc activityNamed(iface: ProjectInterface; name: string): InterfaceActivity =
  for act in iface.publicActivities:
    if act.name == name:
      return act
  raise newException(ValueError, "no lifted activity named " & name)

proc configNamed(act: InterfaceActivity; name: string): InterfaceConfigKey =
  for key in act.config:
    if key.name == name:
      return key
  raise newException(ValueError, "no config key named " & name)

suite "L3 — the lift carries each exported activity's signature":

  test "every constructor-shaped activity is lifted, and only those":
    let iface = liftedInterface("l3LiftProducer")
    var names: seq[string] = @[]
    for act in iface.publicActivities:
      names.add(act.name)
    # `activity "default"` is the bare string form: it declares a NAME
    # and nothing else, so there is no signature to lift. Asserting its
    # ABSENCE is the control that keeps the positive assertion from
    # passing on an implementation that lifts every activity spelling it
    # can see.
    check names == @["sso", "edge"]

  test "the handle type is recorded, not left for a consumer to derive":
    let sso = liftedInterface("l3LiftProducer").activityNamed("sso")
    check sso.handleType == "L3LiftProducerPackageSsoHandle"

  test "typed constructor parameters are carried with their types":
    let sso = liftedInterface("l3LiftProducer").activityNamed("sso")
    check sso.params.len == 1
    check sso.params[0].name == "db"
    check sso.params[0].nimType == "LiftDemoDb"

  test "the `config:` surface is carried WITH its defaults":
    let sso = liftedInterface("l3LiftProducer").activityNamed("sso")
    var keyNames: seq[string] = @[]
    for key in sso.config:
      keyNames.add(key.name)
    check keyNames == @["externalDomain", "externalSecure", "port"]
    let domain = sso.configNamed("externalDomain")
    check domain.nimType == "string"
    # `hasDefault` carried separately from `defaultRepr`: this key is
    # REQUIRED at the `enable` site and an empty `defaultRepr` alone
    # could not say so.
    check not domain.hasDefault
    check domain.defaultRepr == ""
    check domain.description == "The externally visible issuer host."
    let secure = sso.configNamed("externalSecure")
    check secure.nimType == "bool"
    check secure.hasDefault
    check secure.defaultRepr == "true"
    let port = sso.configNamed("port")
    check port.nimType == "int"
    check port.hasDefault
    check port.defaultRepr == "8080"

  test "the services an activity declares are members of its handle":
    let iface = liftedInterface("l3LiftProducer")
    check iface.activityNamed("sso").services == @["zitadel", "bootstrap"]
    check iface.activityNamed("edge").services == @["nginx"]

suite "L3 — the lift carries each exported service":

  test "every service is lifted, with its declaring activity":
    let iface = liftedInterface("l3LiftProducer")
    var rows: seq[string] = @[]
    for svc in iface.publicServices:
      rows.add(svc.activityName & "/" & svc.name)
    check rows == @["sso/zitadel", "sso/bootstrap", "edge/nginx",
                    "/standalone"]

  test "a package-level service has no activity and no handle type":
    for svc in liftedInterface("l3LiftProducer").publicServices:
      if svc.name != "standalone":
        continue
      check svc.activityName == ""
      check svc.handleType == ""
      return
    check false

  test "an activity's service names the handle type it is reached through":
    for svc in liftedInterface("l3LiftProducer").publicServices:
      if svc.name != "zitadel":
        continue
      check svc.activityName == "sso"
      check svc.handleType == "L3LiftProducerPackageSsoHandle"
      return
    check false

  test "the lift attributes exports to the DECLARING package only":
    # Four `package` blocks are expanded in this one test binary and the
    # registries are module-global, so an unfiltered fold would put every
    # package's services on every package's contract. Measured, not
    # assumed: this is exactly the mistake the resource fold cannot
    # avoid (a `resourceType` is declared at module scope) and that this
    # one can.
    let baseline = liftedInterface("l3SigBaseline")
    check baseline.publicActivities.len == 1
    check baseline.publicServices.len == 1
    check baseline.publicActivities[0].name == "api"

suite "L3 — the interface fingerprint discriminates":

  test "an UNRELATED change to the producer leaves the fingerprint alone":
    # The clause that stops the fingerprint being a rebuild-everything
    # hammer. `l3SigSameSignature` differs from `l3SigBaseline` in its
    # service's argv, in a `description` setter and in having a second
    # `args` statement — none of which a consumer compiles against.
    #
    # NOTE ON DIRECTION: this assertion also passes at the base commit,
    # where nothing about a service reaches the interface at all. It is
    # here as the other half of the pair and as the guard that the new
    # payload did not accidentally start carrying the implementation; the
    # test that FAILS before this change is the next one.
    check interfaceFingerprint(namesNormalised("l3SigBaseline")) ==
      interfaceFingerprint(namesNormalised("l3SigSameSignature"))

  test "a SIGNATURE change moves the fingerprint":
    # One `config:` default, 8080 -> 9090, with a byte-identical service
    # body. This is the assertion that fails before the change (both
    # sides hashed to the same digest, because neither carried the
    # `config:` surface) and passes after.
    check interfaceFingerprint(namesNormalised("l3SigBaseline")) !=
      interfaceFingerprint(namesNormalised("l3SigChangedSignature"))

  test "the implementation really did differ (control for the pair)":
    # Without this, "unrelated change does not move the fingerprint"
    # would also pass if the two fixtures had silently become identical
    # — a fixture-drift failure that looks exactly like a success.
    let baseline = packageDefNamed("l3SigBaseline")
    let same = packageDefNamed("l3SigSameSignature")
    check baseline.devEnvBodyHash.len > 0
    check baseline.devEnvBodyHash != same.devEnvBodyHash

  test "the signature pair's service bodies really are identical":
    # The mirror control: if the fixtures had drifted so that
    # `l3SigChangedSignature` differed in its service body too, the
    # positive assertion above would pass for the wrong reason.
    let baseline = liftedInterface("l3SigBaseline")
    let changed = liftedInterface("l3SigChangedSignature")
    check baseline.publicServices.len == changed.publicServices.len
    check baseline.publicServices[0].name == changed.publicServices[0].name
    check baseline.publicActivities[0].configNamed("port").defaultRepr ==
      "8080"
    check changed.publicActivities[0].configNamed("port").defaultRepr ==
      "9090"

  test "moving a declaration down the file does NOT move the fingerprint":
    # TI3: the fingerprint is a projection over the SEMANTIC contract, so
    # every SourceLocation is normalised under `forFingerprint`. The new
    # activity/service rows carry locations at three depths — the
    # activity, each param, each `config:` key — and a `forFingerprint`
    # flag not threaded all the way down would make a comment above a
    # declaration invalidate every consumer. Measured by shifting the
    # locations of a REAL lifted interface.
    var moved = namesNormalised("l3SigBaseline")
    for act in moved.publicActivities.mitems:
      act.location.line += 100
      act.location.file = "somewhere/else.nim"
      for param in act.params.mitems:
        param.location.line += 100
      for key in act.config.mitems:
        key.location.line += 100
    for svc in moved.publicServices.mitems:
      svc.location.line += 100
    check interfaceFingerprint(namesNormalised("l3SigBaseline")) ==
      interfaceFingerprint(moved)

  test "the location shift was real (control)":
    var moved = namesNormalised("l3SigBaseline")
    let before = moved.publicActivities[0].config[0].location.line
    for act in moved.publicActivities.mitems:
      for key in act.config.mitems:
        key.location.line += 100
    check moved.publicActivities[0].config[0].location.line == before + 100
