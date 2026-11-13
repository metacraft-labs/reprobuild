## Shared-Development-Services L1 test fixture for
## ``t_service_lowers_typed_edges_into_the_graph_fragment``.
##
## A package that declares a ``service`` whose configuration is a rendered
## build output, plus a ``devEnv:`` block that still uses
## ``servicePlaceholder`` — the surface this milestone must leave working
## unchanged.
##
## Lives in a separate module from the test main so the auto-generated
## ``runPackageProvider`` shim's ``isMainModule`` guard doesn't fire on the
## test binary. Not named ``t_*`` / ``test_*``, so
## ``scripts/generate_test_edges.nim`` does not register it as a test
## binary of its own.

import repro_project_dsl

const
  ConfigPath* = "etc/sso/config.toml"
  StepsPath* = "etc/sso/steps.yaml"
  RenderConfigActionId* = "render-sso-config"
  RenderStepsActionId* = "render-sso-steps"

var ssoConfig: BuildOutput
var ssoSteps: BuildOutput

package ssoFragmentPkg:
  config:
    issuer: string = "http://localhost:8080"

  executable zitadelBin:
    build:
      output("bin/zitadel")

  build:
    ssoConfig = renderConfigFile(ConfigPath,
      "issuer = \"" &
        readConfigurable[string]("ssoFragmentPkg.issuer") & "\"\n",
      actionId = RenderConfigActionId)
    ssoSteps = renderConfigFile(StepsPath,
      "FirstInstance:\n  Org:\n    Name: dev\n",
      actionId = RenderStepsActionId)

  service sso:
    executable zitadelBin
    args "start-from-init", "--config", ssoConfig.path
    runtimeFile ssoSteps
    on change ssoConfig:
      sendSignal "SIGHUP"

  devEnv:
    activity "stack"
    ## The pre-L1 surface, untouched. ``Shared-Development-Services.md``
    ## §1 names this as the defect L1 begins to close, and L1's gate
    ## requires it to keep working: this milestone is additive.
    servicePlaceholder "legacy-stack",
      metadata = """{"schemaId": "reprobuild.dev-session.service.v1",
        "command": ["bash", "scripts/stack.sh"]}""",
      activities = ["stack"]

## The service record as it stood at MODULE-INIT time, before any
## ``build:`` body ran. Captured here so the test can show WHY
## ``buildPackageFragment`` re-evaluates the service body: in provider
## mode the ``build:`` splice is gated off at module init, so the handle
## the service reads is still unassigned at this point.
let servicesAtModuleInit* = registeredServices("ssoFragmentPkg")

export buildSsoFragmentPkgPackage
export devEnvSsoFragmentPkgPackage
