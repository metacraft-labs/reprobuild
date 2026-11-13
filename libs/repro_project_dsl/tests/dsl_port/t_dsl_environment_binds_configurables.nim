## Shared-Development-Services L5 — an `environment <name>:` declaration
## is a NAMED SET OF BINDINGS TO CONFIGURABLES AND NOTHING ELSE, it
## contributes through the existing resolution lane, and the value it
## binds reaches the service the activity declares.
##
## Governing spec text, quoted because each assertion below is an
## assertion about one of these sentences:
##
## * `Shared-Development-Services.md` §6 — "An environment is a named
##   set of bindings to configurables, and nothing else. The service or
##   activity declares its configurables; an environment binds them; the
##   existing late-binding machinery assembles the result."
## * §6.1 — an environment "needs no new staging, no new merge rules and
##   no new precedence model — only a name, a binding set, and a
##   declared position in the existing precedence order."
## * §6.4 — the selected environment "MUST be a tracked solver input
##   that participates in the graph cache key."
## * L5 `:gate:` — "`environment <name>:` binds configurables and does
##   nothing else … it introduces no new staging, merge rule or
##   precedence model."
##
## WHICH DISCRIMINATOR IS LOAD-BEARING, and it is NOT an exit code.
## Every assertion here rests on a VALUE READ BACK through the real
## `readConfigurable` lane, or on a field of the real lowered
## `DslEnvironmentDef`. At the base commit `8a85af3eb` this file does
## not compile at all — `environment` is not a known package section, so
## the fixture's `environment dev:` lands in the preserved-Nim bucket and
## fails as an undeclared identifier, and `registeredEnvironments`,
## `EnvironmentBindingDef` and `applyEnvironment` do not exist. That makes
## the before-state a COMPILE failure, which is a useless discriminator
## on its own, so the before/after is measured on a SECOND axis as well:
## with the guard mutated so that an environment's bindings are recorded
## but never applied, this file compiles and the value assertions
## REDDEN. The milestone's evidence drawer records both directions.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## The packages are real `package` blocks, the bindings are applied by
## the real `applyEnvironment` through the real `setConfigurable`, and
## the values are read by the real `readConfigurable`. A hand-built
## binding table would test nothing: what is under test is what the
## macro emitted and what the existing configurable lane did with it.
##
## ONE SUITE REGISTERS ITS ENVIRONMENT THROUGH THE RUNTIME API INSTEAD
## OF THROUGH A `package` BLOCK, and it is named here because the
## policy requires every such choice to be justified where a reader
## starts. "L5 — an environment applies ALL-OR-NOTHING" needs an
## environment whose application FAILS PARTWAY, and every binding the
## macro can emit that would fail at apply time is now refused at
## COMPILE time — so no recipe can express one, which is the point of
## that refusal. It is not a mock: the calls are the same
## `registerEnvironment` / `registerEnvironmentApplier` pair
## `l5EnvironmentEmission` emits, the applier body is the same closure
## of `bindEnvironmentConfigurable` calls, and nothing in the lane is
## substituted. It is also the surface L7's resolver will use.

import std/[algorithm, os, sequtils, strutils, unittest]

import repro_project_dsl

## The ladder's OWN type, imported here and nowhere in the library, so
## the `EnvironmentPrecedence` mirror cannot drift from it. `types.nim`
## explains why the mirror exists: `repro_dsl_stdlib` depends on
## `repro_project_dsl`, so the library cannot import this.
import repro_dsl_stdlib/configurables/types as ladder

import ./l5_environment_fixtures

proc resetOwnerConfigurables() =
  ## Put every configurable this file touches back on its DECLARED
  ## default, so a test never reads a value an earlier test bound.
  for key in ["l5Owner.issuer", "l5Owner.retries",
              "l5Owner.sso.externalDomain", "l5Owner.sso.externalSecure"]:
    resetConfigurable(key)

suite "L5 — the environment's declared position in the existing ladder":

  test "EnvironmentPrecedence mirrors ContributionPriority, ordinal for ordinal":
    # The whole content of D-SS6's second half: the environment's
    # position is a value of the EXISTING ladder, recorded rather than
    # re-decided. A mirror that drifted would silently move every
    # environment binding to a different rung.
    check ord(epDefault) == ord(ladder.prDefault)
    check ord(epSet) == ord(ladder.prSet)
    check ord(epOverride) == ord(ladder.prOverride)
    check ord(epForce) == ord(ladder.prForce)
    check ord(high(EnvironmentPrecedence)) == ord(high(ladder.ContributionPriority))

  test "every binding the macro lowered carries epOverride":
    # D-SS6: an environment contributes at `prOverride`. Asserted on
    # every binding of every environment rather than on one, so a future
    # binding form cannot arrive on a different rung unnoticed.
    var seen = 0
    for env in registeredEnvironments("l5Owner"):
      for binding in env.bindings:
        check binding.precedence == epOverride
        inc seen
    check seen == 6

suite "L5 — the lowered record is a name and a binding set":

  test "both environments are registered, in declaration order":
    check registeredEnvironmentNames("l5Owner") == @["dev", "production"]

  test "a package that declares none has none — the control":
    check registeredEnvironmentNames("l5NoEnvironment").len == 0

  test "an environment with NO bindings is registered, with zero bindings":
    # Documented acceptance, not an accident. The empty set is a legal
    # "named set of bindings", and selecting it means "the declared
    # defaults, explicitly". See the fixture's note for the near miss it
    # is weighed against.
    check registeredEnvironmentNames("l5EmptyEnvironment") == @["bare"]
    check registeredEnvironment("l5EmptyEnvironment", "bare")
      .bindings.len == 0
    check environmentOwnedConfigKeys("l5EmptyEnvironment").len == 0
    # And applying it changes nothing.
    applyEnvironment("l5EmptyEnvironment", "bare")
    check readConfigurable[string]("l5EmptyEnvironment.issuer") ==
      "http://localhost:8080"

  test "`dev` binds four configurables, keyed as the config: lane keys them":
    let dev = registeredEnvironment("l5Owner", "dev")
    check dev.name == "dev"
    check dev.packageName == "l5Owner"
    var keys: seq[string] = @[]
    for b in dev.bindings:
      keys.add(b.key)
    # The package-level keys are BYTE-IDENTICAL to what
    # `recordConfigDefault` registered, which is what makes an
    # environment a contributor into the existing table rather than a
    # second one.
    check keys == @["l5Owner.issuer", "l5Owner.retries",
                    "l5Owner.sso.externalDomain",
                    "l5Owner.sso.externalSecure"]
    for key in ["l5Owner.issuer", "l5Owner.retries",
                "l5Owner.sso.externalDomain", "l5Owner.sso.externalSecure"]:
      check key in registeredConfigKeys()

  test "`production` binds a STRICT SUBSET, and that is recorded as such":
    let prod = registeredEnvironment("l5Owner", "production")
    var keys: seq[string] = @[]
    for b in prod.bindings:
      keys.add(b.key)
    check keys == @["l5Owner.issuer", "l5Owner.sso.externalDomain"]

  test "a binding carries the author's expression, verbatim, and its site":
    let dev = registeredEnvironment("l5Owner", "dev")
    check dev.bindings[0].valueRepr == "\"https://login.metacraft-labs.test\""
    check dev.bindings[1].valueRepr == "9"
    check dev.bindings[3].valueRepr == "true"
    check dev.bindings[0].sourceFile.endsWith("l5_environment_fixtures.nim")
    check dev.bindings[0].sourceLine > 0
    # The qualifier/name split is what lets a diagnostic name the
    # ACTIVITY rather than only the composed key.
    check dev.bindings[0].qualifier == ""
    check dev.bindings[0].name == "issuer"
    check dev.bindings[2].qualifier == "sso"
    check dev.bindings[2].name == "externalDomain"

  test "the environment-owned key set is DERIVED from the bindings":
    # §6.6's right column names "any configurable the environment owns".
    # Derived rather than declared, so ownership cannot disagree with
    # the bindings. The union of both environments, de-duplicated.
    check environmentOwnedConfigKeys("l5Owner") ==
      @["l5Owner.issuer", "l5Owner.retries", "l5Owner.sso.externalDomain",
        "l5Owner.sso.externalSecure"]
    check environmentOwnedConfigKeys("l5NoEnvironment").len == 0

  test "the owning site is reportable, for the refusal to quote":
    let site = environmentBindingSite("l5Owner", "l5Owner.issuer")
    check site.startsWith("dev (")
    check site.contains("l5_environment_fixtures.nim")
    check environmentBindingSite("l5Owner", "l5Owner.nosuchkey") == ""

suite "L5 — the bindings reach the configurables, through the existing lane":

  setup:
    resetOwnerConfigurables()

  teardown:
    resetOwnerConfigurables()

  test "nothing applied: every configurable is on its declared default":
    # The control that makes the next two tests mean something. Without
    # it, a test that read `login.metacraft-labs.test` could be reading
    # a default somebody wrote into the recipe.
    check readConfigurable[string]("l5Owner.issuer") ==
      "http://localhost:8080"
    check readConfigurable[int]("l5Owner.retries") == 3
    check readConfigurable[string]("l5Owner.sso.externalDomain") ==
      "localhost"
    check readConfigurable[bool]("l5Owner.sso.externalSecure") == false

  test "`dev` applied: all four keys move":
    applyEnvironment("l5Owner", "dev")
    check readConfigurable[string]("l5Owner.issuer") ==
      "https://login.metacraft-labs.test"
    check readConfigurable[int]("l5Owner.retries") == 9
    check readConfigurable[string]("l5Owner.sso.externalDomain") ==
      "login.metacraft-labs.test"
    check readConfigurable[bool]("l5Owner.sso.externalSecure") == true

  test "`production` applied: the two it binds move, the others do NOT":
    # THE DISCRIMINATOR AGAINST A MERGED BINDING SET. A design that
    # layered `production` onto `dev` would hand a production build
    # `retries = 9` and `externalSecure = true`, which no author wrote
    # for it. Both are asserted to be the DECLARED defaults, not `dev`'s
    # values.
    applyEnvironment("l5Owner", "production")
    check readConfigurable[string]("l5Owner.issuer") ==
      "https://login.metacraft-labs.com"
    check readConfigurable[string]("l5Owner.sso.externalDomain") ==
      "login.metacraft-labs.com"
    check readConfigurable[int]("l5Owner.retries") == 3
    check readConfigurable[bool]("l5Owner.sso.externalSecure") == false

  test "two environments in one process do not blend: the second wins whole":
    # L7 resolves per consuming edge and will apply an environment more
    # than once in one process, so this is the property that has to hold
    # then. `dev` first, `production` second: `issuer` takes
    # `production`'s value and `retries` goes back to its DEFAULT rather
    # than keeping `dev`'s 9 — because `production` is a different
    # resolved configuration and not a patch on `dev`.
    applyEnvironment("l5Owner", "dev")
    check readConfigurable[int]("l5Owner.retries") == 9
    resetOwnerConfigurables()
    applyEnvironment("l5Owner", "production")
    check readConfigurable[string]("l5Owner.issuer") ==
      "https://login.metacraft-labs.com"
    check readConfigurable[int]("l5Owner.retries") == 3

  test "an unknown environment is refused, naming the ones that exist":
    var msg = ""
    try:
      applyEnvironment("l5Owner", "staging")
    except EDslPortMissingKey as err:
      msg = err.msg
    check msg.contains("no environment named `staging`")
    check msg.contains("`dev`")
    check msg.contains("`production`")

suite "L5 — the selection is read in ONE place, and canonicalised":

  test "with nothing selected, both projections are empty":
    delEnv(ReproEnvironmentEnvVar)
    check selectedEnvironmentName() == ""
    check canonicalEnvironmentSelection() == ""

  test "the canonical form folds case and surrounding space":
    # Three spellings of one selection must be ONE cache entry, not
    # three: §6.4 makes this projection the graph cache key's field, and
    # a key that distinguished `dev` from `Dev` would cold-start a build
    # for a difference nobody made.
    for spelling in ["dev", "Dev", "  dev  ", "DEV"]:
      putEnv(ReproEnvironmentEnvVar, spelling)
      check canonicalEnvironmentSelection() == "dev"
    putEnv(ReproEnvironmentEnvVar, "production")
    check canonicalEnvironmentSelection() == "production"
    delEnv(ReproEnvironmentEnvVar)

  test "applySelectedEnvironment applies the selected one and reports it":
    resetOwnerConfigurables()
    putEnv(ReproEnvironmentEnvVar, "production")
    check applySelectedEnvironment("l5Owner") == "production"
    check readConfigurable[string]("l5Owner.issuer") ==
      "https://login.metacraft-labs.com"
    delEnv(ReproEnvironmentEnvVar)
    resetOwnerConfigurables()
    check applySelectedEnvironment("l5Owner") == ""
    check readConfigurable[string]("l5Owner.issuer") ==
      "http://localhost:8080"
    resetOwnerConfigurables()

  test "a selected environment the package does not declare is refused":
    putEnv(ReproEnvironmentEnvVar, "staging")
    var msg = ""
    try:
      discard applySelectedEnvironment("l5Owner")
    except EDslPortMissingKey as err:
      msg = err.msg
    delEnv(ReproEnvironmentEnvVar)
    check msg.contains("REPRO_ENVIRONMENT")
    check msg.contains("declares no environment by that name")

suite "L5 — an environment applies ALL-OR-NOTHING":
  ## §6 makes an environment "a named set of bindings". A set half of
  ## which is in force is neither of the two outcomes §6 describes, and
  ## it was what happened: `applyEnvironment` ran the bindings in
  ## sequence, so a binding that raised left every PRECEDING binding
  ## applied and then propagated the exception. The author saw an error
  ## and the process carried on with a configuration no environment
  ## declares.
  ##
  ## WHY THIS SUITE REGISTERS AN ENVIRONMENT THROUGH THE RUNTIME API
  ## RATHER THAN THROUGH A `package` BLOCK, AND WHY THAT IS NOT A MOCK.
  ## Every binding the MACRO can emit that would fail at apply time is
  ## now refused at compile time (`t_dsl_environment_surface_is_typed`
  ## measures both shapes), so a recipe can no longer express a failing
  ## environment -- which is the point of that fix and makes a recipe
  ## fixture unable to reach this code path at all. The registration
  ## calls used here are the SAME `registerEnvironment` /
  ## `registerEnvironmentApplier` calls `l5EnvironmentEmission` emits,
  ## with the same closure-of-`bindEnvironmentConfigurable` body, and
  ## the apply is the real `applyEnvironment` over the real
  ## `setConfigurable` / `readConfigurable` lane. Nothing is faked or
  ## substituted: no mock, no double, no stub. It is also the surface
  ## L7's resolver will call, since it resolves per consuming edge and
  ## cannot re-read the process environment per edge.

  setup:
    recordConfigDefault[string]("l5Txn", "alpha", "declared-alpha")
    recordConfigDefault[string]("l5Txn", "beta", "declared-beta")
    resetConfigurable("l5Txn.alpha")
    resetConfigurable("l5Txn.beta")

  teardown:
    resetConfigurable("l5Txn.alpha")
    resetConfigurable("l5Txn.beta")

  test "a binding that raises leaves NO earlier binding of the same set in force":
    registerEnvironment(DslEnvironmentDef(packageName: "l5Txn",
      name: "partial", sourceFile: "l5-txn", sourceLine: 1))
    registerEnvironmentApplier("l5Txn", "partial", proc () =
      bindEnvironmentConfigurable("l5Txn", "partial", "l5Txn.alpha",
        "bound-alpha")
      bindEnvironmentConfigurable("l5Txn", "partial", "l5Txn.nosuchkey",
        "bound-nothing"))
    var msg = ""
    try:
      applyEnvironment("l5Txn", "partial")
    except EDslPortMissingKey as err:
      msg = err.msg
    # The refusal still reaches the author, unchanged.
    check msg.contains("which no `config:` block registered")
    # And `alpha` -- applied BEFORE the failure -- is back on its
    # declared default rather than carrying a half-applied environment.
    check readConfigurable[string]("l5Txn.alpha") == "declared-alpha"

  test "THE CONTROL: the same two-binding shape with both keys registered applies BOTH":
    # Without it, the assertion above is satisfied by an
    # `applyEnvironment` that applies nothing at all.
    registerEnvironment(DslEnvironmentDef(packageName: "l5Txn",
      name: "whole", sourceFile: "l5-txn", sourceLine: 2))
    registerEnvironmentApplier("l5Txn", "whole", proc () =
      bindEnvironmentConfigurable("l5Txn", "whole", "l5Txn.alpha",
        "bound-alpha")
      bindEnvironmentConfigurable("l5Txn", "whole", "l5Txn.beta",
        "bound-beta"))
    applyEnvironment("l5Txn", "whole")
    check readConfigurable[string]("l5Txn.alpha") == "bound-alpha"
    check readConfigurable[string]("l5Txn.beta") == "bound-beta"

  test "an override a FAILING environment did not write is left alone":
    # The restore puts back the table that was there, not an empty one:
    # a value some other lane had already overridden must survive a
    # failed environment application.
    setConfigurable("l5Txn.beta", "set-by-somebody-else")
    registerEnvironment(DslEnvironmentDef(packageName: "l5Txn",
      name: "partialtwo", sourceFile: "l5-txn", sourceLine: 3))
    registerEnvironmentApplier("l5Txn", "partialtwo", proc () =
      bindEnvironmentConfigurable("l5Txn", "partialtwo", "l5Txn.alpha",
        "bound-alpha")
      bindEnvironmentConfigurable("l5Txn", "partialtwo", "l5Txn.nosuchkey",
        "bound-nothing"))
    try:
      applyEnvironment("l5Txn", "partialtwo")
    except EDslPortMissingKey:
      discard
    check readConfigurable[string]("l5Txn.alpha") == "declared-alpha"
    check readConfigurable[string]("l5Txn.beta") == "set-by-somebody-else"

suite "L5 — the selection resolves under NIM IDENTIFIER EQUALITY, like the key":
  ## `canonicalEnvironmentSelection` normalizes, and
  ## `l5EnvironmentEmission` refuses a second `environment Dev:` beside
  ## `environment dev:` with `envName.normalize in seenNames` -- so two
  ## lanes already treat those as ONE name. `registeredEnvironment`
  ## compared VERBATIM, so `Dev` was refused as an environment the
  ## package does not declare, under a graph cache key that says it is
  ## the same build as `dev`. Two lanes disagreeing about which
  ## selections are equal is §6.4's hazard; the asymmetry sweep that
  ## found the variant guard found this beside it.

  setup:
    resetOwnerConfigurables()

  teardown:
    delEnv(ReproEnvironmentEnvVar)
    resetOwnerConfigurables()

  test "`applyEnvironment` accepts every spelling of the declared name":
    for spelling in ["dev", "Dev", "DEV", "d_ev"]:
      resetOwnerConfigurables()
      applyEnvironment("l5Owner", spelling)
      check readConfigurable[string]("l5Owner.issuer") ==
        "https://login.metacraft-labs.test"

  test "and a name that is NOT the declared one under that rule is still refused":
    # The control: normalising the comparison must not make the lookup
    # permissive. `devel` normalizes to `devel`, not to `dev`.
    var msg = ""
    try:
      applyEnvironment("l5Owner", "devel")
    except EDslPortMissingKey as err:
      msg = err.msg
    check msg.contains("no environment named `devel`")

  test "`REPRO_ENVIRONMENT=Dev` applies `dev` and REPORTS the declared spelling":
    # The reported name is the DECLARED one, because that is the name
    # the instance key, the state root and the lease address are built
    # from -- a selection's casing must not reach the filesystem.
    putEnv(ReproEnvironmentEnvVar, "Dev")
    check applySelectedEnvironment("l5Owner") == "dev"
    check readConfigurable[string]("l5Owner.issuer") ==
      "https://login.metacraft-labs.test"
    check canonicalEnvironmentSelection() == "dev"

suite "L5 — §6.6's LEFT column: what a consumer MAY say, recorded":

  test "the consumer's scope and lease policy are recorded, per edge":
    let overrides = registeredConsumerInstanceOverrides("l5Consumer")
    check overrides.len == 1
    check overrides[0].consumerPackage == "l5Consumer"
    check overrides[0].targetPackage == "l5Owner"
    check overrides[0].targetService == "zitadel"
    check overrides[0].scopeDeclared
    check overrides[0].scope == sscUser
    check overrides[0].leaseKind == clkDelayed
    check overrides[0].leaseTtlSeconds == 900

  test "`scope` alone leaves the lease UNSET, not `keep`":
    # `clkUnset` is ordinal 0 and is NOT `clkKeep`, although `keep` is
    # `LeaseKind`'s own default. "The consumer said nothing" and "the
    # consumer chose never-reap" are different statements, and only the
    # second is an override of whatever L7 decides by default.
    let only = consumerInstanceOverride("l5ConsumerScopeOnly", "l5Owner",
      "zitadel")
    check only.targetService == "zitadel"
    check only.scopeDeclared
    check only.scope == sscWorkspace
    check only.leaseKind == clkUnset
    check ord(clkUnset) == 0

  test "a package with no overrides has none, and the lookup says so":
    check registeredConsumerInstanceOverrides("l5Owner").len == 0
    check consumerInstanceOverride("l5Owner", "l5Owner", "zitadel")
      .targetService == ""
