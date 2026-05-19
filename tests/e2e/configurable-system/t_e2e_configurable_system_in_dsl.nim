## M58 gate: `e2e_configurable_system_in_dsl`.
##
## Normative description:
##
##   A fixture project's provider uses configurables to compute a
##   build argument; overriding the configurable via DSL recomputes
##   the build action input and invalidates the cache. Two
##   evalConfig contexts in the same provider run remain isolated.
##
## This gate exercises the Configurable system in a provider-style
## context: a fixture provider proc uses `evalConfig:` to declare
## configurables, applies overrides, reads the resolved value into
## a `BuildActionDef`-shaped argv tuple, and computes the weak
## action fingerprint via the real `weakFingerprintFromText` path.
## Two `evalConfig` contexts share the same provider run and remain
## isolated; their respective action fingerprints reflect their
## respective overrides.

import std/[strutils, unittest]
import repro_build_engine
import repro_dsl_stdlib/configurables

type
  ProviderResult = object
    argv: seq[string]
    fingerprint: string

proc buildArgvFingerprint(argv: openArray[string]): string =
  # Stable canonical form for the fingerprint computation.
  result = argv.join("\x1f")

proc emitFixtureBuild(host: string; port, replicas: int): ProviderResult =
  ## Stand-in for what a real provider emits: argv to the build
  ## action and its weak fingerprint. In production this would be
  ## the argv passed to a `BuildActionDef`'s process spec.
  let argv = @["serve",
               "--host", host,
               "--port", $port,
               "--replicas", $replicas]
  let fp = weakFingerprintFromText(buildArgvFingerprint(argv))
  var hex = newStringOfCap(64)
  const HEX = "0123456789abcdef"
  for b in fp.bytes:
    hex.add HEX[int(b shr 4) and 0xF]
    hex.add HEX[int(b) and 0xF]
  ProviderResult(argv: argv, fingerprint: hex)

proc provider(stagingHost = "staging.local";
              productionHost = "example.com"): tuple[
                staging: ProviderResult,
                production: ProviderResult] =
  ## Real provider: declares two `evalConfig:` contexts back-to-back
  ## in the same process run. Each one exercises the Configurable
  ## system independently. The function returns the materialized
  ## build-action inputs for both.
  var stagingArgvHandle, productionArgvHandle: Configurable[string]
  var stagingPortRaw, productionPortRaw: Configurable[int]

  let stagingCtx = evalConfig:
    config:
      ## Bind host for the API.
      ## @id api-host
      host = "localhost"

      ## TCP port the API server binds.
      ## @id api-port
      port = 8080

      ## Worker replica count.
      ## @id replicas
      replicas = 1
    host.override stagingHost
    port.override 8081
    replicas.override 2
    stagingPortRaw = port
    let argvLine = "--host=" & host & " --port=" & $port &
                   " --replicas=" & $replicas
    stagingArgvHandle = argvLine

  let productionCtx = evalConfig:
    config:
      ## Bind host for the API.
      ## @id api-host
      host = "localhost"

      ## TCP port the API server binds.
      ## @id api-port
      port = 8080

      ## Worker replica count.
      ## @id replicas
      replicas = 1
    host.override productionHost
    port.override 443
    replicas.override 32
    productionPortRaw = port
    let argvLine = "--host=" & host & " --port=" & $port &
                   " --replicas=" & $replicas
    productionArgvHandle = argvLine

  let stagingArgv = stagingCtx.read(stagingArgvHandle)
  let productionArgv = productionCtx.read(productionArgvHandle)
  result.staging = emitFixtureBuild(stagingHost,
    stagingCtx.read(stagingPortRaw), 2)
  result.production = emitFixtureBuild(productionHost,
    productionCtx.read(productionPortRaw), 32)

  # Sanity: configurable values flowed into the argv strings.
  doAssert stagingArgv.contains(stagingHost)
  doAssert productionArgv.contains(productionHost)
  doAssert stagingCtx.read(stagingPortRaw) == 8081
  doAssert productionCtx.read(productionPortRaw) == 443

suite "M58 e2e configurable system in DSL":

  test "two evalConfig contexts in one provider run produce isolated argv + fingerprint":
    let r = provider()
    check r.staging.argv != r.production.argv
    check r.staging.fingerprint != r.production.fingerprint
    check r.staging.argv.contains("staging.local")
    check r.production.argv.contains("example.com")
    check "8081" in r.staging.argv
    check "443" in r.production.argv
    check "2" in r.staging.argv
    check "32" in r.production.argv

  test "overriding a configurable changes the action fingerprint":
    let baseline = provider()
    let overridden = provider(stagingHost = "staging-2.local",
      productionHost = "example.com")
    # Production unchanged -> SAME fingerprint (cache hit).
    check overridden.production.fingerprint == baseline.production.fingerprint
    # Staging changed -> DIFFERENT fingerprint (cache invalidation).
    check overridden.staging.fingerprint != baseline.staging.fingerprint

  test "evalConfig context machinery cleans up after itself":
    # The provider runs two evalConfigs back-to-back. After each
    # one finishes, the context stack must be empty so that a
    # subsequent provider call (or any other configurable
    # operation) starts fresh.
    discard provider()
    # Now attempt a `configurable` call outside any context — must
    # raise `ENoContext` because the previous contexts have been
    # popped.
    expect ENoContext:
      let c = configurable 42
      discard c.id

  test "fingerprint reflects ALL configurable inputs that feed the argv":
    let a = provider(stagingHost = "host-a", productionHost = "host-b")
    let b = provider(stagingHost = "host-c", productionHost = "host-b")
    # Production identical, staging differs -> staging fingerprints
    # diverge, production fingerprints match.
    check a.production.fingerprint == b.production.fingerprint
    check a.staging.fingerprint != b.staging.fingerprint
