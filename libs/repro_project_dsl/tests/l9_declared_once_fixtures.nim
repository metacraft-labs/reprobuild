## Shared-Development-Services L9 fixture: a shared service DECLARED
## ONCE — identity, scope, command, readiness, working directory, state
## directory and the `instance` block all on one typed `service` block,
## with NO `servicePlaceholder` anywhere in the package.
##
## That absence is the fixture's whole point, and it is asserted rather
## than described: `t_l9_supervision_facts_reach_the_dev_env_artifact`
## checks every service record's `metadata` is empty, because a
## placeholder's metadata IS the JSON blob. Until L9 a package in this
## shape could reach the supervisor with no probe at all — the typed
## `service` block had no `readiness` setter and
## `serviceSpecFromSummary` refused an empty metadata outright — which
## is why `infra/repro.nim` carried both channels joined by the service
## name.
##
## In a separate module from the test main for the reason L5's and L8's
## fixtures give: under `-d:reproProviderMode` the `package` macro emits
## a `runPackageProvider` shim guarded on `isMainModule`, which would
## take over the test binary. Not named `t_*` / `test_*`, so
## `scripts/generate_test_edges.nim` does not register it as a test
## binary of its own.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## Real `package` blocks, a real `devEnv:` activity with a real
## `config:` block, real `environment` sections and real `contribute:`
## sections, expanded by the real DSL macro and resolved by the real
## `dsl_port_runtime` fold. The claim under test is what the real
## lowering carries, and a fixture that simulated any part of it would
## prove nothing about the DSL an author writes.
##
## WHY TWO PRODUCTS CONTRIBUTE HERE. L9's gate asks for one identity
## provider "consumed by two products", with "both products' relying
## parties as contributions (L8)" and "neither product naming a
## hostname". The two consumer packages below are the reprobuild-side
## model of exactly that: each appends its own relying party and neither
## binds — or even mentions — a hostname. The hostname is bound once, in
## `environment development`, which is the owner's.

import repro_project_dsl

const
  L9SsoStableId* = "com.metacraft-labs.l9-sso"
    ## The same text as the fixture's `identity stable "..."` literal.
    ## `identity stable` requires a STRING LITERAL (§4.2: "A literal
    ## cannot be either, so the restriction is the guarantee"), so this
    ## const cannot be spliced there; the test asserts the two agree
    ## rather than leaving a reader to compare them by eye.
  L9ReadyMarker* = ".repro/l9-sso/ready"
  L9StateDir* = ".repro/l9-sso"
  L9SecondStateDir* = ".repro/l9-sso-journal"
  L9ReadyTimeoutMs* = 600_000
  L9DevDomain* = "login.metacraft-labs.test"
  L9ProductionDomain* = "login.metacraft-labs.com"

package l9SsoOwner:
  executable l9SsoBin:
    build:
      output("bin/l9-sso")

  devEnv:
    activity sso():
      config:
        ## The external identity, declared with NO default so it can
        ## only come from an environment (§6) — which is what makes
        ## "bound ONCE" a property of the recipe rather than a habit.
        externalDomain: string
        ## Whether the issuer URL is https. False only where no edge
        ## fronts it.
        externalSecure: bool = false
        ## The contribution point the two products append to (§5, L8).
        relyingParties: seq[string]

      service sso:
        executable l9SsoBin
        args "--external-domain", externalDomain
        args "--relying-parties"
        args relyingParties
        identity stable "com.metacraft-labs.l9-sso"
        scope workspace
        ## L9's four new setters. Before them each of these lived in a
        ## `servicePlaceholder`'s JSON and nowhere else.
        workingDirectory "."
        stateDirectory L9StateDir
        stateDirectory L9SecondStateDir
        readiness fileExists(L9ReadyMarker, timeoutMs = L9ReadyTimeoutMs)
        instance:
          lease keep
        converge relyingParties

      ## A SECOND service in the same activity, deliberately declaring
      ## NONE of the four. It is the control for every assertion about
      ## the four: without it, an implementation that set the fields
      ## unconditionally — from a default rather than from the body —
      ## would pass every positive case here.
      service ssoProbeless:
        executable l9SsoBin
        args "--no-supervision-facts"
        identity stable "com.metacraft-labs.l9-sso-probeless"
        scope project

    enable sso

  ## The development bindings: the external identity, ONCE. §9.2's
  ## "The development hostname appears **once**, in `environment dev`."
  environment development:
    sso.externalDomain = L9DevDomain
    sso.externalSecure = true

  ## And production, over the SAME definition — the other half of the
  ## gate's first clause. It binds a strict subset, which is also L5's
  ## deferral control: `externalSecure` must stay on its DECLARED
  ## default here rather than inheriting `development`'s `true`.
  environment production:
    sso.externalDomain = L9ProductionDomain

package l9ProductA:
  ## A consumer that contributes one relying party and NAMES NO
  ## HOSTNAME. `l9NoHostnameInEitherProduct` in the test asserts that
  ## second half over this module's own source text.
  contribute:
    append:
      l9SsoOwner.sso.relyingParties = "product-a"

package l9ProductB:
  contribute:
    append:
      l9SsoOwner.sso.relyingParties = "product-b"
