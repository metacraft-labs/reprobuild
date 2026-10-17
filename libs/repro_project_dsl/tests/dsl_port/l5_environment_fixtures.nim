## Shared-Development-Services L5 test fixtures: real `package` blocks
## carrying `environment <name>:` binding sets, the configurables they
## bind, and one consumer-shaped package carrying an
## `instanceOverrides <package>.<service>:` block.
##
## In a separate module from the test main for the reason
## `l3_lift_fixtures.nim` / `l4_lift_fixtures.nim` give: under
## `-d:reproProviderMode` the `package` macro emits a
## `runPackageProvider` shim guarded on `isMainModule`, which would take
## over the test binary. Not named `t_*` / `test_*`, so
## `scripts/generate_test_edges.nim` does not register it as a test
## binary of its own.
##
## MOCK POLICY — NO MOCKS. These are real `package` blocks expanded by
## the real DSL macro; the records the tests read are the ones the macro
## emitted, and the configurable values are the ones the real
## `setConfigurable` / `readConfigurable` lane carries.
##
## FIXTURE DESIGN, one thing varying per pair:
##
## * `l5Owner` declares BOTH authoring surfaces of §6.1 — a
##   package-level `config:` key and an activity's — and binds them in
##   TWO environments. `production` deliberately binds a STRICT SUBSET:
##   §6 gives an environment no obligation to bind everything, and a key
##   it does not bind must keep its declared default rather than
##   inheriting the other environment's value. A design that merged the
##   two binding sets would pass every other assertion in this file.
## * `l5NoEnvironment` declares the same configurables and NO
##   environment. It is the control for every "the binding did it"
##   claim: the same keys, the same defaults, nothing bound.

import repro_project_dsl

package l5Owner:
  config:
    issuer: string = "http://localhost:8080"
    retries: int = 3

  devEnv:
    activity sso():
      config:
        externalDomain: string = "localhost"
        externalSecure: bool = false
        ## No default on purpose: this is a REQUIRED configurable --
        ## a slot with NO SEED -- and L3's `hasDefault` is what turns
        ## that distinction on. §6 gives it two routes to a value, an
        ## `environment` binding or an argument at `enable sso(...)`,
        ## and THIS fixture takes the second (`enable sso(adminUser =
        ## "root")` below) so the file keeps a required key that NO
        ## environment binds.
        ##
        ## Two earlier revisions of this comment were wrong, in
        ## opposite directions. The first claimed the walker refused a
        ## binding to such a key while there was no refusal at all --
        ## the binding was accepted and raised at module init only when
        ## the environment happened to be selected. The second claimed
        ## the refusal as correct behaviour; it was not, because it made
        ## §6's and §9.1's own worked examples illegal. Both routes, and
        ## both of the refusals that replaced that one, are measured in
        ## `t_dsl_environment_surface_is_typed.nim` and in
        ## `../t_l5_environment_reaches_the_service_argv.nim`.
        adminUser: string

      service zitadel:
        args "--domain", externalDomain, "--secure", $externalSecure
        identity stable "com.metacraft-labs.sso"
        scope workspace

    enable sso(adminUser = "root")

  environment dev:
    issuer = "https://login.metacraft-labs.test"
    retries = 9
    sso.externalDomain = "login.metacraft-labs.test"
    sso.externalSecure = true

  environment production:
    ## A STRICT SUBSET of `dev`'s keys. `retries` and
    ## `sso.externalSecure` are deliberately absent.
    issuer = "https://login.metacraft-labs.com"
    sso.externalDomain = "login.metacraft-labs.com"

## An environment that binds NOTHING. §6 makes an environment "a named
## set of bindings"; the empty set is a legal member of that
## description, and selecting it means "the declared defaults,
## explicitly". Accepted rather than refused, and asserted below so the
## acceptance is documented behaviour rather than an accident -- the
## near miss it is weighed against is a MISINDENTED binding, which lands
## at package top level instead and fails there as an undeclared
## identifier rather than being swallowed here.
package l5EmptyEnvironment:
  config:
    issuer: string = "http://localhost:8080"

  environment bare:
    discard

package l5NoEnvironment:
  config:
    issuer: string = "http://localhost:8080"

  devEnv:
    activity sso():
      config:
        externalDomain: string = "localhost"

      service zitadel:
        args "--domain", externalDomain

## §6.6's LEFT COLUMN, in a consumer-shaped package: the instance scope
## and this consumer's own lease policy, about somebody else's service.
## Nothing here binds a configurable, and nothing here resolves
## anything.
package l5Consumer:
  instanceOverrides l5Owner.zitadel:
    scope user
    lease delayed(900)

package l5ConsumerScopeOnly:
  instanceOverrides l5Owner.zitadel:
    scope workspace
