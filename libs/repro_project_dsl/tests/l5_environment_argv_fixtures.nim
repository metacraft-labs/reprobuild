## Shared-Development-Services L5 provider-mode fixture: one service
## definition whose argv is built from the configurables two environments
## bind, plus the rendered configuration file whose BYTES they decide.
##
## In a separate module from the test main because under
## `-d:reproProviderMode` the `package` macro emits a
## `runPackageProvider` shim guarded on `isMainModule`, which would take
## over the test binary. Not named `t_*` / `test_*`, so
## `scripts/generate_test_edges.nim` does not register it as a test
## binary of its own.
##
## MOCK POLICY — NO MOCKS. A real `package` block with a real
## `environment`, expanded by the real DSL macro.
##
## ONE definition, not two. That is the whole point of the gate's
## headline clause -- "one service definition resolved under two
## environments" -- so a fixture with a `dev` service and a `prod`
## service would prove nothing.

import repro_project_dsl

const ArgvConfigPath = "etc/sso/config.toml"

var argvSsoConfig*: BuildOutput

package l5ArgvPkg:
  config:
    issuer: string = "http://localhost:8080"

  executable l5ArgvBin:
    build:
      output("bin/sso")

  build:
    argvSsoConfig = renderConfigFile(ArgvConfigPath,
      "issuer = \"" & readConfigurable[string]("l5ArgvPkg.issuer") & "\"\n")

  devEnv:
    activity sso():
      config:
        externalDomain: string = "localhost"
        externalSecure: bool = false

      service zitadel:
        executable l5ArgvBin
        args "start-from-init", "--domain", externalDomain,
             "--secure", $externalSecure
        identity stable "com.metacraft-labs.sso"
        scope workspace

    enable sso

  environment dev:
    issuer = "https://login.metacraft-labs.test"
    sso.externalDomain = "login.metacraft-labs.test"
    sso.externalSecure = true

  environment production:
    issuer = "https://login.metacraft-labs.com"
    sso.externalDomain = "login.metacraft-labs.com"
    sso.externalSecure = true

## ---------------------------------------------------------------------
## THE HEADLINE FIXTURE: `Shared-Development-Services.md`'s OWN worked
## shape, which the first revision of L5 refused.
##
## §6's example (line 421) and §9.1's (line 646) both declare
##
##     activity sso(...):
##       config:
##         externalDomain: string      ## NO DEFAULT
##         externalSecure: bool = true
##
## and bind `externalDomain` from an `environment` block. That is §6's
## whole argument -- the external identity is the ENVIRONMENT's to bind
## and nobody else's, and a hostname has no sensible default, which is
## why the spec declares it without one. A `config:` key with no default
## is not SLOT-LESS; it is REQUIRED, and an `environment` binding is one
## of exactly two things that may satisfy it.
##
## WHAT MAKES THIS DIFFERENT FROM `l5ArgvPkg` ABOVE, which is the only
## reason for a second package: every configurable `l5ArgvPkg` binds has
## a declared default, so every one of its assertions would pass under
## an implementation that refused a required key outright. This one
## cannot compile at all unless a required key has a slot.
##
## `externalSecure` is DELIBERATELY left unbound by `production` and
## bound by `dev`: the control for "the required key's value came from
## the environment" needs a key in the same block whose value did NOT.
##
## `bare` binds `externalSecure` and NOT `externalDomain`, which is the
## RESOLUTION-TIME refusal's fixture: a required key that is bindable
## (two environments bind it) and that the SELECTED environment does
## not bind.

const ReqConfigPath* = "etc/sso-required/config.yaml"
const ReqRenderActionId* = "l5-required-render-config"

package l5ReqPkg:
  executable l5ReqBin:
    build:
      output("bin/sso-required")

  devEnv:
    activity sso():
      config:
        ## The externally visible issuer host. NO DEFAULT, exactly as
        ## §6 and §9.1 declare it.
        externalDomain: string
        ## Whether the issuer URL is https. False only where no edge
        ## fronts it.
        externalSecure: bool = true

      let cfg = renderConfigFile(ReqConfigPath,
        "ExternalDomain: " & externalDomain & "\n" &
          "ExternalSecure: " & $externalSecure & "\n",
        actionId = ReqRenderActionId,
        packageName = "l5ReqPkg")

      service zitadel:
        executable l5ReqBin
        args "start-from-init", "--config", cfg.path,
             "--domain", externalDomain, "--secure", $externalSecure
        identity stable "com.metacraft-labs.sso-required"
        scope workspace

    ## No argument for `externalDomain`: the environment is what
    ## satisfies it, which is the claim under test.
    enable sso

  environment dev:
    sso.externalDomain = "login.metacraft-labs.test"
    sso.externalSecure = false

  environment production:
    sso.externalDomain = "login.metacraft-labs.com"

  environment bare:
    sso.externalSecure = false
