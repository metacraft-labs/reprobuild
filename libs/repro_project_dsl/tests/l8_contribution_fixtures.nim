## Shared-Development-Services L8 fixture: the FOUR-CELL MATRIX, one
## owner and two consumers, all against the SAME BASE.
##
## In a separate module from the test main for the reason L5's fixture
## gives: under `-d:reproProviderMode` the `package` macro emits a
## `runPackageProvider` shim guarded on `isMainModule`, which would take
## over the test binary. Not named `t_*` / `test_*`, so
## `scripts/generate_test_edges.nim` does not register it as a test
## binary of its own.
##
## MOCK POLICY -- NO MOCKS. Real `package` blocks with a real `devEnv:`
## activity, a real `config:` block and real `contribute:` sections,
## expanded by the real DSL macro and resolved by the real
## `dsl_port_runtime` fold. Nothing here stubs the configurable lane,
## the contribution registry or the macro: the whole claim of L8 is
## about what the real lowering does, and a fixture that simulated it
## would prove nothing about the DSL an author writes.
##
## WHY FOUR KEYS AND ONE BASE. The gate asks for "the four-cell matrix
## -- append-low, append-high, replace-low, replace-high -- against the
## same base". So every one of the four keys is declared with the
## IDENTICAL construction default and receives the IDENTICAL low-priority
## append from consumer A; only consumer B's cell differs. The cells are
## then comparable by construction rather than by a reader checking that
## two fixtures happen to agree.
##
## The base, for all four keys:
##   * the owner's construction default, a `coReplace` at `epDefault`:
##     @["owner-default"]
##   * consumer A's `append` at `epSet`: "consumer-a"
##
## And consumer B's cell, per key:
##   * appendLow    -- `append`          at `epSet`      "cell"
##   * appendHigh   -- `appendForce`     at `epForce`    "cell"
##   * replaceLow   -- `replace`         at `epSet`      @["cell"]
##   * replaceHigh  -- `replaceOverride` at `epOverride` @["cell"]

import repro_project_dsl

package l8MatrixOwner:
  executable l8MatrixBin:
    build:
      output("bin/sso")

  devEnv:
    activity sso():
      config:
        ## The four contribution points. `seq[string]` is the ordered
        ## collection the configurable lane carries, so these are
        ## ordinary configurables whose type is a collection -- §5's
        ## "This needs no new mechanism. A collection is a
        ## configurable." There is no `collections:` block and no
        ## bespoke primitive.
        appendLow: seq[string] = @["owner-default"]
        appendHigh: seq[string] = @["owner-default"]
        replaceLow: seq[string] = @["owner-default"]
        replaceHigh: seq[string] = @["owner-default"]

        ## A fifth point with NO default, to assert the rule that an
        ## ordered collection with no default seeds the EMPTY collection
        ## and is NOT a required configurable.
        noDefault: seq[string]

        ## A sixth, bound by an `environment` below. L5's own deferral
        ## note predicted that "an environment binding is a `replace` at
        ## `epOverride` in the terms L8 will introduce"; this is the key
        ## that measures it, including that a consumer's lower append is
        ## then DISCARDED with a diagnostic rather than vanishing.
        envBound: seq[string] = @["owner-default"]

        ## A seventh that nothing ever contributes to, so an EMPTY
        ## collection's behaviour on argv has a case.
        emptyPoint: seq[string] = @[]

      ## A second service, so an EMPTY contribution point's effect on
      ## argv is measurable against a service whose other arguments are
      ## known.
      service zitadelEmpty:
        executable l8MatrixBin
        args "--only-this"
        args emptyPoint
        identity stable "com.metacraft-labs.l8-matrix-empty"
        scope project

      service zitadel:
        executable l8MatrixBin
        ## The members reach the service's ARGV. This is the same lane
        ## L5 proved for a scalar; the discriminator here is that the
        ## tokens come from two packages' contributions folded together.
        args "start-from-init", "--relying-parties"
        args appendLow
        identity stable "com.metacraft-labs.l8-matrix"
        scope workspace
        ## D-SS10 (§7.1): a service that `converge`s a contribution point
        ## must declare an evaluable readiness probe, because the
        ## registration's `dependsOn` onto it completes on that probe.
        ## Never evaluated by these cases.
        readiness fileExists(".repro/l8-matrix/ready")
        ## L8: the members of this point are REGISTERED in the instance
        ## once it answers, and the instance mints one identifier per
        ## member.
        converge appendLow

    enable sso

  ## The environment that binds `envBound`. Selected by
  ## `REPRO_ENVIRONMENT` / `applyEnvironment`, never applied by default,
  ## so the unbound fold is also observable.
  environment dev:
    sso.envBound = @["from-environment"]

package l8MatrixConsumerA:
  ## The LOWER contribution, identical for every cell. This is the
  ## contribution an authoritative `append` must leave present and a
  ## winning `replace` must discard WITH a diagnostic.
  contribute:
    append:
      l8MatrixOwner.sso.appendLow = "consumer-a"
      l8MatrixOwner.sso.appendHigh = "consumer-a"
      l8MatrixOwner.sso.replaceLow = "consumer-a"
      l8MatrixOwner.sso.replaceHigh = "consumer-a"
      ## The append an `environment` binding must DISCARD with a
      ## diagnostic rather than silently drop.
      l8MatrixOwner.sso.envBound = "consumer-a"

package l8MatrixConsumerB:
  ## The CELL. One operation/priority pair per key.
  contribute:
    append:
      l8MatrixOwner.sso.appendLow = "cell"
    appendForce:
      l8MatrixOwner.sso.appendHigh = "cell"
    replace:
      l8MatrixOwner.sso.replaceLow = @["cell"]
    replaceOverride:
      l8MatrixOwner.sso.replaceHigh = @["cell"]

  ## A SECOND `contribute:` section in the same package. Honouring only
  ## the first would be a silent drop, so there are two and the test
  ## asserts both landed.
  contribute:
    append:
      l8MatrixOwner.sso.noDefault = @["from-second-section"]

## A PACKAGE-LEVEL contribution point, so the package-level `config:`
## lowering (`emitM2ConfigDefaults`) has a case of its own. The two
## authoring surfaces are lowered by two emitters and L7's review found
## what one predicate answering for both costs.
package l8PackageLevelOwner:
  config:
    siteList: seq[string] = @["owner-site"]

package l8PackageLevelConsumer:
  contribute:
    append:
      l8PackageLevelOwner.siteList = "consumer-site"
