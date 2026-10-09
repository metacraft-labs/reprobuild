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

import std/[strutils, unittest]

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
