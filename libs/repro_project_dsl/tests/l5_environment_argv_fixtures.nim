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
